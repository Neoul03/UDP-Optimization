#!/bin/bash
# sweep_expected_goodput.sh — 정직한 기댓값 곡선: rate별 p(good)과 평균 goodput
set -u
N="${1:-6}"; DUR="${2:-15}"; RATES="${3:-46 50 52 54 56 58}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/expected_${TS}; mkdir -p "$LOG"
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
for b in $RATES; do
  printf "b=%-3s: " "$b" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do
    d="$LOG/b${b}_${i}"; mkdir -p "$d"
    ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & SP=$!
    sleep 2
    ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 & MP=$!
    ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
    ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"; wait $SP $MP 2>/dev/null || true
    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    if [ -z "$tx" ] || awk -v t="${tx:-0}" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then st="FLAKE"
    elif awk -v l="${loss:-100}" 'BEGIN{exit !(l < 1)}'; then st="GOOD"; else st="BAD"; fi
    echo "$b $i $st rx=$rx busy=$busy tx=$tx" >> "$LOG/raw.txt"
    printf "%s" "$(echo $st|cut -c1)" | tee -a "$LOG/summary.txt"
  done
  echo "" | tee -a "$LOG/summary.txt"
done
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
