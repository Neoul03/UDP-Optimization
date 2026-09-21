#!/bin/bash
# trials_consumer_prio.sh — 가설: startup 스케줄링 경쟁이 state를 가른다
# consumer에 우선순위를 주면 good state 진입률이 오르는가?
set -u
N="${1:-10}"; RATE="${2:-46}"; DUR="${3:-15}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/consumer_prio_${TS}; mkdir -p "$LOG"
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

trial() {  # <arm> <prefix> <i>
  local arm="$1"; local pfx="$2"; local i="$3"
  local d="$LOG/${arm}_${i}"; mkdir -p "$d"
  ssh sslab4 "$pfx taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & local SP=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${RATE}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"; wait $SP 2>/dev/null || true
  local rx tx loss st
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
  if [ -z "$tx" ] || awk -v t="${tx:-0}" -v o="$RATE" 'BEGIN{exit !(t < o*0.97)}'; then st="FLAKE"
  elif awk -v l="${loss:-100}" 'BEGIN{exit !(l < 1)}'; then st="GOOD"
  else st="BAD"; fi
  echo "$arm $i $st rx=$rx loss=${loss}% tx=$tx" >> "$LOG/raw.txt"
  echo -n "$(echo $st|cut -c1)"
}

run_arm() {
  local arm="$1"; local pfx="$2"
  printf "%-12s: " "$arm" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do trial "$arm" "$pfx" "$i" | tee -a "$LOG/summary.txt"; done
  local g; g=$(grep -c "^$arm .* GOOD" "$LOG/raw.txt" 2>/dev/null || echo 0)
  printf "  → GOOD %s/%s\n" "$g" "$N" | tee -a "$LOG/summary.txt"
}

run_arm "normal"   ""
run_arm "nice-20"  "sudo nice -n -20"
run_arm "fifo50"   "sudo chrt -f 50"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
