#!/bin/bash
# ab_gso_gro.sh — Tier1 #3: GSO와 GRO를 분리 측정 (지금까지 둘을 동시에 바꿔 비교했음)
# 최적 구성 기준: 1.5MB, DIM off, shed off
#   GSO on  = -l 65000 (UDP_SEGMENT 발동)   GSO off = -l 8972 (분할 불필요)
#   GRO on  = IPERF3_UDP_GRO 기본           GRO off = IPERF3_UDP_GRO=0
set -u
REPS="${1:-3}"; DUR="${2:-20}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/gso_gro_${TS}; mkdir -p "$LOG"
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

point() {  # <arm> <gro 0/1> <l> <offered> <rep>
  local arm="$1"; local gro="$2"; local len="$3"; local b="$4"; local rep="$5"
  local try=0 rx tx loss busy d env=""
  [ "$gro" = "0" ] && env="IPERF3_UDP_GRO=0 "
  while : ; do
    d="$LOG/${arm}_b${b}_r${rep}$([ $try -gt 0 ] && echo _t$try)"; mkdir -p "$d"
    ssh sslab4 "${env}taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & local SP=$!
    sleep 2
    ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 & local MP=$!
    ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l $len -t $DUR" > "$d/client.log" 2>&1 || true
    ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"; wait $SP $MP 2>/dev/null || true
    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    if [ -n "$tx" ] && awk -v t="$tx" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then
      try=$((try+1)); [ $try -le 2 ] && continue
    fi
    break
  done
  printf "%-14s b=%-3s r%s | rx=%-6s loss=%-8s busy=%s\n" "$arm" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" | tee -a "$LOG/summary.txt"
}

for rep in $(seq 1 $REPS); do
  echo "===== REP $rep =====" | tee -a "$LOG/summary.txt"
  for b in 25 35 43; do
    point "GSOon_GROon"   1 65000 "$b" "$rep"
    point "GSOon_GROoff"  0 65000 "$b" "$rep"
    point "GSOoff_GROon"  1 8972  "$b" "$rep"
    point "GSOoff_GROoff" 0 8972  "$b" "$rep"
  done
  echo "" | tee -a "$LOG/summary.txt"
done
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
