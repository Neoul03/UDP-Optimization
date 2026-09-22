#!/bin/bash
# probe_mtu1500.sh — MTU 1500 적용범위 판정 Step 0
#  목적: (1) sender가 MTU 1500에서 얼마나 밀 수 있는지 (receiver를 stress 할 수 있나?)
#        (2) receiver 천장 (UDP GSO+GRO / GSO only / plain / TCP)
#
#  전제: 셋업은 스크립트 밖에서 이미 적용되어 있어야 함 (governor glob 루프가
#        permission classifier에 걸리므로 의도적으로 분리했다):
#    - 양쪽 ens81f0np0 MTU 1500
#    - 양쪽 cpufreq governor = performance
#    - sslab4: combined 1, 모든 msi_irq -> core1, adaptive-rx off,
#              rmem_max=512M rmem_default=1.5M, autotune/early_drop/shed = 0
#  스크립트는 위 전제를 assert 만 하고 측정만 수행한다.
set -u
DUR="${1:-15}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/mtu1500_probe_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

# ---- assert 전제 ----
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 1500 ] || { echo "FATAL $h mtu=$m (expected 1500)"; exit 1; }
  g=$(ssh $h "cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor")
  [ "$g" = performance ] || { echo "FATAL $h governor=$g"; exit 1; }
  echo "$h mtu=$m gov=$g" | tee -a "$LOG/verify.log"
done
ssh sslab4 "uname -r; sysctl -n net.core.rmem_default net.ipv4.udp_rx_shed; ethtool -c $IF | grep -i 'adaptive-rx'" | tee -a "$LOG/verify.log"

: > "$LOG/raw.txt"
run() {  # run <name> <proto> <env> <rate> <blksize>
  local name="$1"; local proto="$2"; local xopt="$3"; local b="$4"; local l="${5:-65000}"
  local d="$LOG/$name"; mkdir -p "$d"
  # GSO는 env가 아니라 blksize > gso_size(=MTU-28=1472) 조건으로 켜진다.
  #   l=65000 -> GSO on (44 seg),  l=1472 -> GSO off (plain per-datagram)
  local copt="-u -b ${b}G -l $l"
  [ "$b" = "0" ] && copt="-u -b 0 -l $l"
  [ "$proto" = tcp ] && copt="-l 1M"

  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "$xopt taskset -c 1 $IPERF_MOD -c $SRV_IP -t $DUR $copt" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true

  local rx tx loss busy soft
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  tx=$(grep sender   "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  soft=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){s+=$9;m++}}  END {if(m)printf "%.0f",s/m}'    "$d/mpstat.log")
  printf "%-16s | tx=%-6s rx=%-6s loss=%-7s rxbusy=%-4s soft=%-4s\n" \
    "$name" "${tx:-NA}" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "${soft:-NA}%" | tee -a "$LOG/summary.txt"
  echo "$name tx=${tx:-NA} rx=${rx:-NA} loss=${loss:-NA} busy=${busy:-NA} soft=${soft:-NA}" >> "$LOG/raw.txt"
}

echo "=== MTU 1500 probe (dur=${DUR}s, true single core both sides) ===" | tee -a "$LOG/summary.txt"
echo "--- A. capability, -b 0 (unlimited offer) ---" | tee -a "$LOG/summary.txt"
run "gso_gro_b0"   udp "IPERF3_UDP_GRO=1" 0 65000   # GSO on  + app GRO on
run "gso_nogro_b0" udp "IPERF3_UDP_GRO=0" 0 65000   # GSO on  + app GRO off  (*loss/rx 무의미, busy만 유효)
run "plain_b0"     udp "IPERF3_UDP_GRO=0" 0 1472    # GSO off + app GRO off  (순수 per-datagram)
echo "--- B. TCP baseline ---" | tee -a "$LOG/summary.txt"
run "tcp"          tcp "" 0

echo "--- C. UDP rate ladder (GSO+GRO) ---" | tee -a "$LOG/summary.txt"
for b in 10 15 20 25 30 35; do run "udp_b${b}" udp "IPERF3_UDP_GRO=1" "$b" 65000; done

ssh sslab4 "pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
