#!/bin/bash
# sweep_fanin.sh — 한 UDP 소켓에 sender 수를 늘려가며 GRO 가 어디서 무너지는가
#
# TCP 에 없고 UDP 에만 있는 경우가 "여러 sender → 소켓 하나"다. 이때 GRO 는
# 흐름별로 따로 모아야 하는데 상한이 있다:
#   GRO_HASH_BUCKETS 8, MAX_GRO_SKBS 8, UDP_GRO_CNT_MAX 64
# 흐름 수가 이 상한을 넘으면 조기 flush 가 나고 merge factor 가 떨어진다.
# merge factor 가 떨어지면 skb 수가 늘고, 우리가 측정한 per-skb 스택 비용이
# 그대로 처리량 손실로 돌아온다.
#
# 관측량:
#   goodput            — 처리량
#   avg_bytes_per_call — recvmsg 한 번이 가져오는 바이트 = GRO super-skb 크기
#                        (= merge factor x 8972). 이게 이 실험의 핵심 지표다.
#
#   usage: sweep_fanin.sh [reps] [total_rate]
set -u
N="${1:-3}"; RATE="${2:-40}"; SEGS="${3:-7}"; DUR=12
SRV_IP=192.168.11.238; P=5301
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/fanin_s${SEGS}_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
CH=$(ssh sslab4 "ethtool -l ens81f0np0 | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
echo "combined=$CH  rate=${RATE}G  segs=$SEGS  (segs>1 이면 GSO 가 선 위에 같은 흐름을 연속으로 깔아 GRO 가 흐름을 동시에 붙들 필요가 없다 -> 흐름 수에 무감각해진다. 버킷 압력을 재려면 segs=1)" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <nflows> <i>
  local nf="$1" i="$2"
  local d="$LOG/f${nf}_$i"; mkdir -p "$d"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_fanin $SRV_IP $P 8972 $SEGS $((DUR-2)) $RATE $nf" > "$d/tx.log" 2>&1
  wait $SP $MP 2>/dev/null || true
  local got off avg busy
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  avg=$(grep -oE 'avg_bytes_per_call=[0-9]+' "$d/sink.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  # sender flake 는 버린다 (CLAUDE.md: tx < 0.97 x offered)
  local ok; ok=$(awk -v o="${off:-0}" -v r="$RATE" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  local mf; mf=$(awk -v a="${avg:-0}" 'BEGIN{printf "%.1f", a/8972}')
  printf "  flows=%-3s #%-2s  goodput=%-7s merge=%-5s (avg=%-6s)  busy=%s%%  offered=%s%s\n" \
     "$nf" "$i" "${got:-NA}" "$mf" "${avg:-NA}" "${busy:-NA}" "${off:-NA}" \
     "$([ "$ok" = 1 ] || echo '  <-- FLAKE, 제외')" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$nf ${got:-0} ${avg:-0} ${busy:-0}" >> "$LOG/raw.txt"
}

ssh sslab4 "sudo sysctl -w net.core.rmem_default=4194304 net.core.rmem_max=4194304 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null"
for i in $(seq 1 $N); do
  for nf in 1 2 4 8 12 16 32 64; do one "$nf" "$i"; done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{g[$1]+=$2; a[$1]+=$3; b[$1]+=$4; n[$1]++}
 END{for(k in n) printf "flows=%-3s goodput=%6.2f  merge=%5.1f  busy=%3.0f%%  (n=%d)\n",
     k, g[k]/n[k], a[k]/n[k]/8972, b[k]/n[k], n[k]}' "$LOG/raw.txt" | sort -t= -k2 -n | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
