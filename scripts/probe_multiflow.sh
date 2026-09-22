#!/bin/bash
# probe_multiflow.sh — 5번: multi-flow 에서 무엇이 무너지는가
#
# 두 가지를 분리해서 본다. 지금까지 전부 단일 흐름이었다.
#
#  A. many -> one  (소켓 1개, sender N개)
#     UDP 고유 패턴(서버 소켓이 여러 클라이언트를 받음). 버퍼/캐시 분석은 그대로
#     적용되지만 **GRO 가 무너진다**: 병합은 same-flow 끼리만 되고
#     (`net/core/gro.c:333` hash 불일치 -> same_flow=0), 버킷은 8개뿐이며
#     (`GRO_HASH_BUCKETS 8`, `MAX_GRO_SKBS 8`) GRO 상태는 NAPI poll 하나를
#     넘어 살지 않는다. 따라서 M 개 flow 가 섞이면 병합 깊이 ~ (poll당 패킷)/M.
#     예측 (c): M 이 커질수록 bytes/call 이 떨어지고 천장이 내려간다.
#
#  B. many -> many (소켓 N개, sender N개)
#     워킹셋이 N배가 된다. 1·2 번에서 워킹셋이 LLC 를 넘으면 무너짐을 확인했으므로
#     소켓당 버퍼를 그대로 두면 N 이 커질 때 총 워킹셋이 절벽을 넘어야 한다.
#     예측 (c): 소켓당 버퍼를 1/N 로 줄이면 천장이 유지된다.
#     -> 이것이 사실이면 **전역 캐시 예산이 필요하다**는 직접 근거가 된다.
#
# 모든 수신은 여전히 cpu1 한 코어. sender 는 코어를 나눠 쓴다(송신이 병목이면
# 수신 측정이 무의미해지므로).
#
#   usage: probe_multiflow.sh <mode: one|many> <N_flows> [reps] [rate_total]
set -u
MODE="${1:?one|many}"; NF="${2:?flows}"; REPS="${3:-3}"; TOTAL="${4:-48}"
DUR=12; IF=ens81f0np0
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/mf_${MODE}${NF}_${TS}; mkdir -p "$LOG"
SRV_IP=192.168.11.238; BASE_PORT=5400

RING=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
ssh sslab4 "uname -r" | tee "$LOG/verify.log"
echo "mode=$MODE flows=$NF total=${TOTAL}G ring=$RING" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

# 흐름당 속도
PER=$(awk -v t="$TOTAL" -v n="$NF" 'BEGIN{printf "%.2f", t/n}')

one() {  # one <bufname> <bytes_per_socket> <i>
  local bn="$1"; local bytes="$2"; local i="$3"
  local d="$LOG/${bn}_$i"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes net.core.rmem_max=$bytes net.ipv4.udp_rx_shed=0 >/dev/null"

  local pids=""
  if [ "$MODE" = one ]; then
    # 소켓 1개. sender N 개가 같은 포트로 쏜다 (src port 가 달라 flow 는 N 개)
    ssh sslab4 "taskset -c 1 /home/chanseo/udp_sink $SRV_IP $BASE_PORT 2 $DUR" > "$d/sink0.log" 2>&1 &
    pids="$!"
  else
    # 소켓 N 개. 전부 cpu1 에서 돈다
    for f in $(seq 0 $((NF-1))); do
      ssh sslab4 "taskset -c 1 /home/chanseo/udp_sink $SRV_IP $((BASE_PORT+f)) 2 $DUR" > "$d/sink$f.log" 2>&1 &
      pids="$pids $!"
    done
  fi
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  # sender: 흐름마다 다른 코어 (송신이 병목이 되지 않도록)
  for f in $(seq 0 $((NF-1))); do
    local port=$BASE_PORT
    [ "$MODE" = many ] && port=$((BASE_PORT+f))
    ssh sslab3 "taskset -c $((f+1)) /home/chanseo/udp_blast $SRV_IP $port 8972 7 $((DUR-2)) $PER" > "$d/blast$f.log" 2>&1 &
  done
  wait $MP 2>/dev/null || true
  for p in $pids; do wait $p 2>/dev/null || true; done

  local tot=0 bpc=0 cnt=0
  for f in "$d"/sink*.log; do
    local g b
    g=$(grep -oE 'goodput=[0-9.]+' "$f" | cut -d= -f2)
    b=$(grep -oE 'avg_bytes_per_call=[0-9]+' "$f" | cut -d= -f2)
    [ -n "${g:-}" ] && tot=$(awk -v a="$tot" -v x="$g" 'BEGIN{print a+x}')
    [ -n "${b:-}" ] && { bpc=$(awk -v a="$bpc" -v x="$b" 'BEGIN{print a+x}'); cnt=$((cnt+1)); }
  done
  [ "$cnt" = 0 ] && { echo "  (sink 실패)" | tee -a "$LOG/summary.txt"; return; }
  bpc=$(awk -v a="$bpc" -v n="$cnt" 'BEGIN{printf "%.0f", a/n}')
  local busy
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  printf "  %-5s flows=%-2s %-5s #%-2s total_got=%-7s busy=%-4s bytes/call=%s\n" \
    "$MODE" "$NF" "$bn" "$i" "$tot" "${busy:-NA}%" "$bpc" | tee -a "$LOG/summary.txt"
  echo "$MODE $NF $bn $tot ${busy:-0} $bpc" >> "$LOG/raw.txt"
}

# 소켓당 버퍼: 1M 고정  vs  1M/N (전역 예산을 유지하는 배분)
PERSOCK=$(awk -v n="$NF" 'BEGIN{v=int(1048576/n); if(v<65536) v=65536; print v}')
for rep in $(seq 1 $REPS); do
  one "buf1M"   1048576    "$rep"
  one "bufdiv"  "$PERSOCK" "$rep"
done

echo "" | tee -a "$LOG/summary.txt"
awk '{k=$3; g[k]+=$4; b[k]+=$5; p[k]+=$6; n[k]++}
 END{for(k in n) printf "%-7s total_got=%6.2f  busy=%3.0f%%  bytes/call=%6.0f  (n=%d)\n",
   k, g[k]/n[k], b[k]/n[k], p[k]/n[k], n[k]}' "$LOG/raw.txt" | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
