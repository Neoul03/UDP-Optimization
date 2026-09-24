#!/bin/bash
# bench_multicore.sh — 단일 소켓(CPU) 멀티코어 환경에서 전역 예산이 유효한가
#
# 지금까지 모든 측정이 `combined 1` + cpu1 고정이었다. 실제 배포는 RSS 가
# 흐름을 여러 큐에 뿌리고 큐마다 코어가 붙는다. 여기서 두 가지가 달라진다:
#
#   1. **ring 발자국이 큐 수만큼 곱해진다.** ring 128 이면 큐당 2MB 이고
#      큐가 4개면 8MB, 8개면 16MB 로 L3(18MB) 의 대부분을 차지한다.
#      커널은 ring 을 볼 수 없으므로 이것은 전부 udp_rmem_cache_pct 에 반영돼야 한다.
#   2. **흐름이 어느 코어에서 처리될지 RSS 가 정한다.** 앱이 도는 코어와
#      다르면 producer/consumer 가 캐시를 공유하지 못한다 — 단일코어 실험에서
#      공유 캐시 레벨이 처리량을 0.40/0.61/0.94 로 갈랐던 그 효과다.
#      aRFS(ntuple)는 흐름을 앱이 있는 코어의 큐로 유도해 그것을 맞춘다.
#
# arm:
#   static   : autotune 끔, rmem 고정
#   nobudget : autotune 켬, 예산 끔
#   budget   : autotune 켬, 예산 켬
# 각 arm 을 aRFS off/on 으로 돌린다.
#
#   usage: bench_multicore.sh <queues> [reps] [total_rate]
set -u
NQ="${1:-4}"; N="${2:-3}"; TOTAL="${3:-48}"; DUR=12; IF=ens81f0np0
NS=$((NQ*2))                       # 소켓은 큐의 2배
PER=$(awk -v t="$TOTAL" -v n="$NS" 'BEGIN{printf "%.2f", t/n}')
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/mc${NQ}_${TS}; mkdir -p "$LOG"
SRV_IP=192.168.11.238; BASE=5400

TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/verify.log"
echo "queues=$NQ sockets=$NS per=${PER}G total=${TOTAL}G" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

sc() { ssh sslab4 "sudo sysctl -w $* >/dev/null"; }

run() {  # run <label> <sysctls> <arfs 0|1> <i>
  local lbl="$1" scs="$2" arfs="$3" i="$4"
  local d="$LOG/${lbl}_$i"; mkdir -p "$d"
  sc "$scs"
  ssh sslab4 "sudo ethtool -K $IF ntuple $([ "$arfs" = 1 ] && echo on || echo off) >/dev/null 2>&1; \
      echo $([ "$arfs" = 1 ] && echo 32768 || echo 0) | sudo tee /proc/sys/net/core/rps_sock_flow_entries >/dev/null; \
      for q in /sys/class/net/$IF/queues/rx-*; do echo $([ "$arfs" = 1 ] && echo 4096 || echo 0) | sudo tee \$q/rps_flow_cnt >/dev/null 2>&1 || true; done"
  local pids=""
  for f in $(seq 0 $((NS-1))); do
    local core=$(( f % NQ ))          # 소켓을 코어에 고루 분배
    ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c $core /home/chanseo/udp_sink $SRV_IP $((BASE+f)) 2 $DUR" > "$d/s$f.log" 2>&1 &
    pids="$pids $!"
  done
  sleep 1
  ssh sslab4 "mpstat -P 0-$((NQ-1)) 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  for f in $(seq 0 $((NS-1))); do
    ssh sslab3 "taskset -c $((f+1)) /home/chanseo/udp_blast $SRV_IP $((BASE+f)) 8972 7 $((DUR-2)) $PER" >/dev/null 2>&1 &
  done
  wait $MP 2>/dev/null || true
  for p in $pids; do wait $p 2>/dev/null || true; done
  local sum=0 busy
  for f in "$d"/s*.log; do local g; g=$(grep -oE 'goodput=[0-9.]+' "$f"|cut -d= -f2); [ -n "${g:-}" ] && sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}'); done
  # 수신에 쓰인 코어들의 평균 busy
  busy=$(awk -v nq="$NQ" '$3 ~ /^[0-9]+$/ && $3+0 < nq && $4 ~ /^[0-9.]+$/ {n++; if(n>nq*2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  printf "  %-10s arfs=%s #%-2s total=%-7s busy=%s%%\n" "$lbl" "$arfs" "$i" "$sum" "${busy:-NA}" | tee -a "$LOG/summary.txt"
  echo "$lbl $arfs $sum ${busy:-0}" >> "$LOG/raw.txt"
}

BASE_SC="net.core.rmem_max=536870912 net.ipv4.udp_rx_shed=0 net.ipv4.udp_rmem_autotune_max=67108864"
for arfs in 0 1; do
  echo "===== aRFS=$arfs =====" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do
    run "static"   "$BASE_SC net.core.rmem_default=1048576 net.ipv4.udp_rmem_autotune=0" "$arfs" "$i"
    run "nobudget" "$BASE_SC net.core.rmem_default=1048576 net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=0" "$arfs" "$i"
    run "budget"   "$BASE_SC net.core.rmem_default=1048576 net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50" "$arfs" "$i"
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{k=$1" arfs="$2; g[k]+=$3; b[k]+=$4; n[k]++}
 END{for(k in n) printf "%-18s total=%6.2f  busy=%3.0f%%  (n=%d)\n", k, g[k]/n[k], b[k]/n[k], n[k]}' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
sc "net.ipv4.udp_rmem_autotune=0 net.core.rmem_default=212992 net.core.rmem_max=212992 net.ipv4.udp_rmem_cache_pct=50"
ssh sslab4 "sudo ethtool -K $IF ntuple off >/dev/null 2>&1; echo 0 | sudo tee /proc/sys/net/core/rps_sock_flow_entries >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
