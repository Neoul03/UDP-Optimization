#!/bin/bash
# trials_state_entry.sh — 고정 rate에서 good-state 진입 "확률"을 통계적으로 측정
# 이유: 3 reps로는 60% 확률 사건이 3/3 나올 확률이 22%라 "결정적"이라 오판하기 쉬움.
# 구성별로 N회 반복해 진입률을 낸다.
set -u
N="${1:-10}"; RATE="${2:-46}"; DUR="${3:-15}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/state_entry_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0
ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/threaded /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null 2>&1 || true
  sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=1572864 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_early_drop=0 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1

trial() {  # <arm> <dim> <shed> <i>
  local arm="$1"; local dim="$2"; local shed="$3"; local i="$4"
  local d="$LOG/${arm}_${i}"; mkdir -p "$d"
  ssh sslab4 "sudo ethtool -C $IF adaptive-rx $([ $dim = 1 ] && echo on || echo off) 2>/dev/null; sudo sysctl -w net.ipv4.udp_rx_shed=$shed >/dev/null"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & local SP=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${RATE}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"; wait $SP 2>/dev/null || true
  local rx tx loss
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
  local st="?"
  if [ -n "$tx" ] && awk -v t="$tx" -v o="$RATE" 'BEGIN{exit !(t < o*0.97)}'; then st="FLAKE"
  elif [ -n "$loss" ] && awk -v l="$loss" 'BEGIN{exit !(l < 1)}'; then st="GOOD"
  else st="BAD"; fi
  echo "$arm $i $st rx=$rx loss=${loss}% tx=$tx" >> "$LOG/raw.txt"
  echo -n "$(echo $st | cut -c1)"
}

for arm in "DIMoff_shedOFF 0 0" "DIMon_shedOFF 1 0" "DIMoff_shedON 0 1" "DIMon_shedON 1 1"; do
  set -- $arm
  printf "%-16s @%sG: " "$1" "$RATE" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do trial "$1" "$2" "$3" "$i" | tee -a "$LOG/summary.txt"; done
  g=$(grep -c "^$1 .* GOOD" "$LOG/raw.txt" 2>/dev/null || echo 0)
  f=$(grep -c "^$1 .* FLAKE" "$LOG/raw.txt" 2>/dev/null || echo 0)
  printf "  → GOOD %s/%s (flake %s)\n" "$g" "$N" "$f" | tee -a "$LOG/summary.txt"
done
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 net.ipv4.udp_rx_shed=0 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
