#!/bin/bash
# sweep_collapse_curve.sh — 논문 Fig: goodput vs offered rate, 3 arms (1c, gsogro)
# S0 stock(208K, off) / S1 +autotune / S2 +autotune+shed
set -u
REPS="${1:-2}"
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/collapse_curve_${TS}
mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238
IF=ens81f0np0
DUR=12

ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true
  sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null
  sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=212992 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done" >> "$LOG/setup.log" 2>&1
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = "9000" ] || { echo "FATAL: $h MTU=$m" | tee -a "$LOG/run.log"; exit 1; }
done

set_arm() { ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=$1 net.ipv4.udp_rmem_autotune_max=536870912 net.ipv4.udp_early_drop=0 net.ipv4.udp_rx_shed=$2" >> "$LOG/run.log" 2>&1; }

run_point() {
  local name="$1" b="$2"
  local d="$LOG/$name"; mkdir -p "$d"
  local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP 2>/dev/null || true
  local rx tx
  rx=$(grep receiver "$d/client.log" | tail -1)
  tx=$(grep sender "$d/client.log" | tail -1 | grep -oE '[0-9.]+ Gbits/sec' | head -1)
  echo "$name | tx=$tx | $rx" | tee -a "$LOG/summary.txt"
}

for rep in $(seq 1 "$REPS"); do
  echo "===== REP $rep =====" | tee -a "$LOG/run.log"
  set_arm 0 0; for b in 24 28 32 36 40 50 60 0; do run_point "S0_r${rep}_b${b}" $b; done
  set_arm 1 0; for b in 24 28 32 36 40 50 60 0; do run_point "S1_r${rep}_b${b}" $b; done
  set_arm 1 1; for b in 24 28 32 36 40 50 60 0; do run_point "S2_r${rep}_b${b}" $b; done
done
ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
echo "DONE. $LOG/summary.txt" | tee -a "$LOG/run.log"
