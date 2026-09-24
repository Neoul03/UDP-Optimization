#!/bin/bash
# sweep_rx_usecs.sh — 붕괴의 원인이 "coalescing 주기가 키운 버스트"인가
#
# adaptive-rx 를 켜면 48G 에서 bistable 하고 끄면 47.92 로 고정된다. DIM 이
# 무언가 나쁜 값을 고르고 있다는 뜻인데, **무엇이** 나쁜지는 아직 모른다.
#
# 가설: coalescing 주기가 길어지면 CPU 를 깨우기 전에 ring 에 쌓이는 패킷이
# 많아지고, 그 버스트가 고정 크기 수신 버퍼를 넘긴다. 그렇다면 DIM 을 끄고
# rx-usecs 를 **정적으로** 크게 잡아도 같은 붕괴가 나와야 한다.
#
# 이 가설이 맞으면 우리 논지가 강해진다: 필요한 버퍼 크기는 속도만의 함수가
# 아니라 **인터럽트 모더레이션의 함수**이기도 하다. 그런데 그 값은 앱도 관리자도
# 볼 수 없고 DIM 이 런타임에 바꾼다. 버퍼를 사람이 정하라는 말이 성립하지 않는다.
#
# 두 버퍼에서 잰다: 1M(고정) 과 autotune. 가설이 맞으면 큰 버퍼가 흡수해야 한다.
#
#   usage: sweep_rx_usecs.sh [reps] [rate]
set -u
N="${1:-3}"; RATE="${2:-48}"; DUR=12; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/rxusecs_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
echo "rate=${RATE}G  adaptive-rx off 로 고정하고 rx-usecs 만 바꾼다" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <buf_label> <usecs> <i>
  local buf="$1" us="$2" i="$3"
  local d="$LOG/${buf}_u${us}_$i"; mkdir -p "$d"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $((DUR-2)) $RATE" > "$d/tx.log" 2>&1
  wait $SP $MP 2>/dev/null || true
  local got off busy ok rb
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  ok=$(awk -v o="${off:-0}" -v r="$RATE" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  %-9s usecs=%-4s #%-2s got=%-7s busy=%s%%%s\n" "$buf" "$us" "$i" "${got:-NA}" "${busy:-NA}" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=${off}")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$buf $us ${got:-0} ${busy:-0}" >> "$LOG/raw.txt"
}

ssh sslab4 "sudo ethtool -C $IF adaptive-rx off >/dev/null 2>&1"; sleep 2
for buf in fixed1M autotune; do
  if [ "$buf" = fixed1M ]; then
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
        net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null"
  else
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
        net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
        net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=0 >/dev/null"
  fi
  for us in 4 8 16 32 64 128 256; do
    ssh sslab4 "sudo ethtool -C $IF rx-usecs $us >/dev/null 2>&1"; sleep 1
    for i in $(seq 1 $N); do one "$buf" "$us" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; s[k]+=$3; ss[k]+=$3*$3; b[k]+=$4; n[k]++; if(!(k in mn)||$3<mn[k])mn[k]=$3}
 END{for(k in n){m=s[k]/n[k]; v=ss[k]/n[k]-m*m; sd=(v>0)?sqrt(v):0; split(k,a," ");
   printf "%-9s usecs=%-4s 평균=%6.2f  sd=%5.2f  최소=%6.2f  busy=%3.0f%%  (n=%d)\n",
   a[1], a[2], m, sd, mn[k], b[k]/n[k], n[k]}}' "$LOG/raw.txt" | sort -k1,1 -k2.7n | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF rx-usecs 8 >/dev/null 2>&1; sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
