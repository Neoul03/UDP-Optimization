#!/bin/bash
# verify_cache_budget.sh — 전역 캐시 예산 검증
#
# 배경: 절벽은 합산 워킹셋(ring descriptor + 모든 sk_rcvbuf)에 있고 임계값은 LLC
#   크기다. 소켓 수는 무관하다. 따라서 소켓별 상한으로는 표현할 수 없다 —
#   "4MB 는 하나면 안전하고 여덟이면 위험"을 각 소켓이 알 방법이 없기 때문.
#
# 두 부분으로 나눈다.
#
# [1] 동기 사례 — SO_RCVBUF 를 쓰는 앱은 예산이 손댈 수 없다
#   udp_sink 는 원래 SO_RCVBUF 로 64MB 를 요청한다. 평범하고 합법적인 요청이다.
#   8 소켓이 각자 그러면 워킹셋 512MB = L3 의 28배가 된다.
#   rmem_max 로만 막을 수 있고, SO_RCVBUF 는 SOCK_RCVBUF_LOCK 을 세워
#   **autotune 과 예산을 모두 우회한다**. 이것이 문제의 크기를 보여준다.
#
# [2] 예산 검증 — SO_RCVBUF 를 안 쓰는 앱
#   UDP_SINK_NO_RCVBUF=1 이면 소켓이 rmem_default 로 출발하고 autotune 이 키운다.
#   여기서 예산이 합을 잡는지 본다. 반증 arm(pct=0) 필수.
set -u
REPS="${1:-3}"; DUR=12; NF=8; PER=6; IF=ens81f0np0
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/budget_${TS}; mkdir -p "$LOG"
SRV_IP=192.168.11.238; BASE=5400

RING=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
[ "$RING" = 128 ] || { echo "FATAL ring=$RING"; exit 1; }
ssh sslab4 "uname -r; dmesg | grep -o 'receive budget sized.*' | tail -1" | tee "$LOG/verify.log"
: > "$LOG/raw.txt"

# run <label> <env> <sysctl string>
run() {
  local lbl="$1"; local env="$2"; local sc="$3"; local i="$4"
  local d="$LOG/${lbl}_$i"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w $sc >/dev/null"
  local pids=""
  for f in $(seq 0 $((NF-1))); do
    ssh sslab4 "$env taskset -c 1 /home/chanseo/udp_sink $SRV_IP $((BASE+f)) 2 $DUR" > "$d/sink$f.log" 2>&1 &
    pids="$pids $!"
  done
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  # 중간 스냅샷: 실제 rcvbuf 분포와 UDP 전체 메모리(페이지)
  ( sleep $((DUR/2))
    ssh sslab4 "ss -uam state unconnected 2>/dev/null | grep -oE 'rb[0-9]+' | sort -u | tr '\n' ' '; echo; awk '/^UDP:/{print \"udp_mem_pages=\"\$5}' /proc/net/sockstat" ) > "$d/snap.txt" 2>&1 &
  local SS=$!
  for f in $(seq 0 $((NF-1))); do
    ssh sslab3 "taskset -c $((f+1)) /home/chanseo/udp_blast $SRV_IP $((BASE+f)) 8972 7 $((DUR-2)) $PER" > "$d/blast$f.log" 2>&1 &
  done
  wait $MP $SS 2>/dev/null || true
  for p in $pids; do wait $p 2>/dev/null || true; done

  local tot=0
  for f in "$d"/sink*.log; do
    local g; g=$(grep -oE 'goodput=[0-9.]+' "$f" | cut -d= -f2)
    [ -n "${g:-}" ] && tot=$(awk -v a=$tot -v x=$g 'BEGIN{print a+x}')
  done
  local busy rb mem
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  rb=$(head -1 "$d/snap.txt" 2>/dev/null)
  mem=$(grep -oE 'udp_mem_pages=[0-9]+' "$d/snap.txt" 2>/dev/null | cut -d= -f2)
  printf "  %-14s #%-2s total=%-7s busy=%-4s rcvbuf=[%s] mem_pages=%s\n" \
    "$lbl" "$i" "$tot" "${busy:-NA}%" "${rb:-?}" "${mem:-?}" | tee -a "$LOG/summary.txt"
  echo "$lbl $tot ${busy:-0} ${mem:-0}" >> "$LOG/raw.txt"
}

BASE_SC="net.ipv4.udp_rx_shed=0 net.core.rmem_default=1048576"

echo "=== [1] 동기 사례: 앱이 SO_RCVBUF 로 64MB 씩 요청 (8 소켓) ===" | tee -a "$LOG/summary.txt"
for i in $(seq 1 $REPS); do
  # rmem_max 가 클램프하면 안전, 크면 각자 64MB 를 가져간다
  run "clamped_1M"  "" "$BASE_SC net.core.rmem_max=1048576   net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=50" "$i"
  run "unclamped"   "" "$BASE_SC net.core.rmem_max=536870912 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=50" "$i"
done

echo "" | tee -a "$LOG/summary.txt"
echo "=== [2] 예산 검증: SO_RCVBUF 미사용, autotune 이 1M 에서 키움 ===" | tee -a "$LOG/summary.txt"
AT="net.core.rmem_max=536870912 net.ipv4.udp_rmem_autotune_max=67108864"
for i in $(seq 1 $REPS); do
  run "at_off"      "UDP_SINK_NO_RCVBUF=1" "$BASE_SC $AT net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=50" "$i"
  run "budget_on"   "UDP_SINK_NO_RCVBUF=1" "$BASE_SC $AT net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50" "$i"
  run "budget_off"  "UDP_SINK_NO_RCVBUF=1" "$BASE_SC $AT net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=0"  "$i"
done

echo "" | tee -a "$LOG/summary.txt"
awk '{g[$1]+=$2; b[$1]+=$3; m[$1]+=$4; n[$1]++}
 END{for(k in n) printf "%-14s total=%6.2f  busy=%3.0f%%  mem_pages=%8.0f  (n=%d)\n",
   k, g[k]/n[k], b[k]/n[k], m[k]/n[k], n[k]}' "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=50 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
