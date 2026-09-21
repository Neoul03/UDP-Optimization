#!/bin/bash
# trials_pacing.sh — 가설: sender의 버스트 구조가 bistable 진입을 좌우한다
#  app1000 : 기본 (application pacing, 1ms 틱 → 큰 버스트)
#  app100  : --pacing-timer 100 (10배 잘게)
#  app20   : --pacing-timer 20  (50배 잘게)
#  fq      : --fq-rate (커널 fq qdisc 기반 매끄러운 pacing)
set -u
N="${1:-10}"; RATE="${2:-46}"; DUR="${3:-15}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/pacing_${TS}; mkdir -p "$LOG"
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
ssh sslab3 "sudo ip link set $IF mtu 9000" > "$LOG/sender_setup.txt" 2>&1

trial() {
  local arm="$1"
  local opts="$2"
  local i="$3"
  local d="$LOG/${arm}_${i}"
  mkdir -p "$d"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${RATE}G -l 65000 -t $DUR $opts" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP 2>/dev/null || true
  local rx tx loss st
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
  if [ -z "$tx" ] || awk -v t="${tx:-0}" -v o="$RATE" 'BEGIN{exit !(t < o*0.97)}'; then
    st="FLAKE"
  elif awk -v l="${loss:-100}" 'BEGIN{exit !(l < 1)}'; then
    st="GOOD"
  else
    st="BAD"
  fi
  echo "$arm $i $st rx=$rx loss=${loss}% tx=$tx" >> "$LOG/raw.txt"
  echo -n "$(echo $st|cut -c1)"
}

run_arm() {
  printf "%-10s: " "$1" | tee -a "$LOG/summary.txt"
  local i
  for i in $(seq 1 $N); do
    trial "$1" "$2" "$i" | tee -a "$LOG/summary.txt"
  done
  local g f
  g=$(grep -c "^$1 .* GOOD" "$LOG/raw.txt" 2>/dev/null || true)
  f=$(grep -c "^$1 .* FLAKE" "$LOG/raw.txt" 2>/dev/null || true)
  printf "  → GOOD %s/%s (flake %s)\n" "${g:-0}" "$N" "${f:-0}" | tee -a "$LOG/summary.txt"
}

run_arm "app1000" ""
run_arm "app100"  "--pacing-timer 100"
run_arm "app20"   "--pacing-timer 20"
run_arm "app5"    "--pacing-timer 5"

ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
