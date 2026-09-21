#!/bin/bash
# trials_tipping_time.sh — good state가 무너지기까지의 시간 분포 측정 (60s 런)
set -u
N="${1:-8}"; RATE="${2:-46}"; DUR="${3:-60}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/tipping_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0
ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/threaded /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null 2>&1 || true
  sudo ethtool -C $IF adaptive-rx off 2>/dev/null || true
  sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=1572864 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_early_drop=0 net.ipv4.udp_rx_shed=0 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1
for i in $(seq 1 $N); do
  d="$LOG/run$i"; mkdir -p "$d"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & SP=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${RATE}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"; wait $SP 2>/dev/null || true
  # 첫 loss>1% 구간 = 전이 시점
  tip=$(grep -E "^\[  5\]   [0-9]" "$d/server.log" | awk '{gsub(/[()%]/,"",$12); if ($12+0 > 1) {split($3,a,"-"); print a[1]; exit}}')
  avg=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  echo "run$i: tip_at=${tip:-none} avg=${avg}G" | tee -a "$LOG/summary.txt"
done
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
