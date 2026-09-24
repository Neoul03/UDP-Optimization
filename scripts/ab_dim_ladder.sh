#!/bin/bash
# ab_dim_ladder.sh — adaptive-rx(DIM) 가 붕괴를 만드는가, 사다리 전체에서
#
# CLAUDE.md 는 "DIM 이 원인"을 **철회된 주장**으로 기록하고 있다. 그 철회의 근거는
# 46G 한 점, N=10, iperf3, 6.6.9 였다. 그런데 셋 다 지금은 못 믿을 근거다:
#   - iperf3 -b 는 pacing quantization 으로 가짜 손실을 만든다 (나중에 밝혀짐)
#   - 한 점에서 잰 결론을 전 구간으로 확장한 것 (측정 원칙 2 위반)
#   - 커널이 6.6.9 였고 지금은 6.18.53 이다
#
# 48G 한 점에서 udp_blast->udp_sink 로 다시 재니 on 은 cv 20%, off 는 cv 0.005%
# 로 갈렸다. 한 점으로 다시 같은 실수를 하지 않기 위해 사다리 전체를 잰다.
#
# shed 는 끈다 - shed 가 붕괴를 덮으면 DIM 효과가 안 보인다.
#
#   usage: ab_dim_ladder.sh [reps]
set -u
N="${1:-5}"; DUR=12; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/dimladder_${TS}; mkdir -p "$LOG"
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <dim> <rate> <i>
  local dim="$1" b="$2" i="$3"
  local d="$LOG/${dim}_b${b}_$i"; mkdir -p "$d"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $((DUR-2)) $b" > "$d/tx.log" 2>&1
  wait $SP $MP 2>/dev/null || true
  local got off busy ok
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  ok=$(awk -v o="${off:-0}" -v r="$b" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  dim=%-3s b=%-3s #%-2s got=%-7s busy=%s%%%s\n" "$dim" "$b" "$i" "${got:-NA}" "${busy:-NA}" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=${off}")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$dim $b ${got:-0} ${busy:-0}" >> "$LOG/raw.txt"
}

ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null"
for dim in on off; do
  ssh sslab4 "sudo ethtool -C $IF adaptive-rx $dim >/dev/null 2>&1"
  sleep 2
  for i in $(seq 1 $N); do
    for b in 32 40 44 48 52 56; do one "$dim" "$b" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
# 평균만으로는 bistable 을 못 본다. sd 와 최솟값을 같이 찍는다.
awk '{k=$1" "$2; s[k]+=$3; ss[k]+=$3*$3; b[k]+=$4; n[k]++; if(!(k in mn)||$3<mn[k])mn[k]=$3; if($3>mx[k])mx[k]=$3}
 END{for(k in n){m=s[k]/n[k]; v=ss[k]/n[k]-m*m; sd=(v>0)?sqrt(v):0;
   split(k,a," "); printf "dim=%-3s %3sG  평균=%6.2f  sd=%5.2f  cv=%4.1f%%  최소=%6.2f  최대=%6.2f  busy=%3.0f%%  (n=%d)\n",
   a[1], a[2], m, sd, (m>0?100*sd/m:0), mn[k], mx[k], b[k]/n[k], n[k]}}' "$LOG/raw.txt" | sort -k2 -n | sort -k1,1 | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1; sudo sysctl -w net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
