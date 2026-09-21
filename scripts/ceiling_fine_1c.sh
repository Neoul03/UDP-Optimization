#!/bin/bash
# ceiling_fine_1c.sh — 수정판(autotune+shed) 무손실 천장 정밀 확정. 30s, 1G 단위, 3 reps.
set -u
REPS="${1:-3}"; TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/ceiling_fine_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0; DUR=30
ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null
  sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=212992 net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=536870912 net.ipv4.udp_early_drop=0 net.ipv4.udp_rx_shed=1 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1
for h in sslab3 sslab4; do m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}'); [ "$m" = "9000" ] || { echo "FATAL $h MTU=$m"|tee -a "$LOG/run.log"; exit 1; }; done
ssh sslab4 "uname -r; sysctl -n net.ipv4.udp_rx_shed" | tee "$LOG/verify.log"
for rep in $(seq 1 $REPS); do
 for b in 32 33 34 35 36 37; do
  d="$LOG/r${rep}_b${b}"; mkdir -p "$d"
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 & MP=$!
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & SP=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"; wait $SP $MP 2>/dev/null || true
  rx=$(grep receiver "$d/client.log"|tail -1); tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1)
  busy=$(awk '$2==1 {s+=100-$12; n++} END {if(n)printf "%.0f", s/n}' "$d/mpstat.log")
  echo "r${rep}_b${b} | tx=$tx | $rx | c1busy=${busy}%" | tee -a "$LOG/summary.txt"
 done
done
ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"; ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
echo "DONE. $LOG/summary.txt" | tee -a "$LOG/run.log"
