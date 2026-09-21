#!/bin/bash
# ① perf 캐시 카운터로 good/bad state 메커니즘 검증  ② autotune cap 스윕
set -u
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/cache_cap_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0
PERF=/usr/lib/linux-tools/6.6.9/perf

base_setup() {
ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=212992 net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rx_shed=1 net.ipv4.udp_early_drop=0 >/dev/null
" > "$LOG/setup.log" 2>&1
}

# ---------- ① perf 캐시 ----------
perf_point() {
  local name="$1"; local b="$2"; local d="$LOG/$name"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune_max=536870912 >/dev/null"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & local SP=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t 30" > "$d/client.log" 2>&1 & local CP=$!
  sleep 5
  ssh sslab4 "sudo $PERF stat -C 1 -e cycles,instructions,cache-references,cache-misses,LLC-load-misses -- sleep 12" > "$d/perf.txt" 2>&1
  ssh sslab4 "ss -uampi 'sport = 5201' 2>/dev/null | head -6" > "$d/ss.txt" 2>&1
  wait $CP 2>/dev/null || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"; wait $SP 2>/dev/null || true
  local rx loss
  rx=$(grep receiver "$d/client.log" | tail -1)
  loss=$(echo "$rx" | grep -oE '\(([0-9.]+)%\)' | tr -d '()%')
  echo "--- $name offered=${b}G loss=${loss}% ---" | tee -a "$LOG/summary.txt"
  echo "$rx" | tee -a "$LOG/summary.txt"
  grep -E 'cycles|instructions|cache-references|cache-misses|LLC-load-misses|insn per cycle' "$d/perf.txt" | sed 's/^ */  /' | tee -a "$LOG/summary.txt"
  grep -oE 'skmem:\(r[0-9]+,rb[0-9]+' "$d/ss.txt" | head -1 | sed 's/^/  /' | tee -a "$LOG/summary.txt"
  echo "" | tee -a "$LOG/summary.txt"
}

# ---------- ② autotune cap 스윕 ----------
cap_point() {
  local cap="$1"; local capname="$2"; local b="$3"
  local d="$LOG/cap_${capname}_b${b}"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune_max=$cap >/dev/null"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 20" > "$d/mpstat.log" 2>&1 & local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t 20" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"; wait $SP $MP 2>/dev/null || true
  local rx busy
  rx=$(grep receiver "$d/client.log" | tail -1 | sed 's/\[  5\]   0.00-2[0-9.]*  sec  *//')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>4){id+=$13;m++}} END {if(m)printf "%.0f", 100-id/m}' "$d/mpstat.log")
  echo "cap=${capname} b=${b}G | $rx | busy=${busy}%" | tee -a "$LOG/summary.txt"
}

base_setup
echo "===== ① perf cache counters (good vs bad) =====" | tee -a "$LOG/summary.txt"
for rep in 1 2 3; do
  perf_point "r${rep}_good_b33" 33
  perf_point "r${rep}_maybebad_b35" 35
done
echo "===== ② autotune cap sweep =====" | tee -a "$LOG/summary.txt"
for rep in 1 2; do
 for b in 35 40 0; do
  cap_point 1048576   "1M"   $b
  cap_point 4194304   "4M"   $b
  cap_point 16777216  "16M"  $b
  cap_point 536870912 "512M" $b
 done
done
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune_max=536870912 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
