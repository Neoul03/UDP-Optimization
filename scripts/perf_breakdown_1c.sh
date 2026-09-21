#!/bin/bash
# perf_breakdown_1c.sh — Phase 2: 고정 rate에서 receiver core1 함수별 비용 분해 (진짜 단일코어)
# 전제: baseline_confirm_1c.sh와 동일 셋업이 이미 적용된 상태.
set -u
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/perf_breakdown_${TS}
mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238
DUR=15

run_perf() {
  local name="$1" scmd="$2" ccmd="$3"
  local d="$LOG/$name"; mkdir -p "$d"
  ssh sslab4 "$scmd" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab3 "$ccmd" > "$d/client.log" 2>&1 &
  local CP=$!
  sleep 3   # 램프업 후 정상 상태에서 perf
  ssh sslab4 "cd /tmp && sudo /usr/lib/linux-tools/6.6.9/perf record -F 499 -C 1 -o perf_${name}.data -- sleep 8 >/dev/null 2>&1; sudo /usr/lib/linux-tools/6.6.9/perf report -i perf_${name}.data --stdio --no-children -F overhead,symbol 2>/dev/null | grep -v '^#' | grep -v '^$' | head -30; sudo rm -f perf_${name}.data" > "$d/perf_top.txt" 2>&1
  wait $CP 2>/dev/null || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP 2>/dev/null || true
  grep -E 'receiver' "$d/client.log" | tail -1 >> "$d/perf_top.txt"
  echo "== $name ==" | tee -a "$LOG/summary.txt"
  head -12 "$d/perf_top.txt" | tee -a "$LOG/summary.txt"
}

# 동일 20G 고정 rate에서 3-way 비교 (모두 1c: server taskset -c 1)
run_perf "tcp_b20" \
  "taskset -c 1 iperf3 -s -B $SRV_IP -1" \
  "taskset -c 1 iperf3 -c $SRV_IP -b 20G -t $DUR"
run_perf "udp_plain_b20" \
  "IPERF3_UDP_GRO=0 taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
  "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b 20G -l 8972 -t $DUR"
run_perf "udp_gsogro_b20" \
  "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
  "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b 20G -l 65000 -t $DUR"
# 천장 근처 (28G) — UDP만
run_perf "udp_gsogro_b28" \
  "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
  "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b 28G -l 65000 -t $DUR"

ssh sslab4 "pgrep -a iperf3 || echo clean"
ssh sslab3 "pgrep -a iperf3 || echo clean"
echo "DONE: $LOG"
