#!/bin/bash
# ab_udp_dim.sh — (순서 재배치) UDP × DIM on/off × shed on/off
# 근거: TCP 실험에서 DIM off가 더 빠르고 훨씬 일관적이었다(39.6±0.1 vs 38.9±2.3).
# 지금까지 UDP 실험은 전부 DIM ON이었으므로, off가 공짜 이득을 줄 가능성 + bistability에 영향 가능.
set -u
REPS="${1:-3}"; DUR="${2:-20}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/udp_dim_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238; IF=ens81f0np0

ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/threaded >/dev/null 2>&1 || true
  echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null
  sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=1572864 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_early_drop=0 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1
for h in sslab3 sslab4; do m=$(ssh $h "ip link show $IF"|grep -o 'mtu [0-9]*'|awk '{print $2}'); [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }; done

point() {  # <arm> <dim> <shed> <offered> <rep>
  local arm="$1"; local dim="$2"; local shed="$3"; local b="$4"; local rep="$5"
  local try=0 rx tx loss busy d
  while : ; do
    d="$LOG/${arm}_b${b}_r${rep}$([ $try -gt 0 ] && echo _retry$try)"; mkdir -p "$d"
    ssh sslab4 "sudo ethtool -C $IF adaptive-rx $([ $dim = 1 ] && echo on || echo off) 2>/dev/null; sudo sysctl -w net.ipv4.udp_rx_shed=$shed >/dev/null"
    local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
    ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
    local SP=$!
    sleep 2
    ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
    local MP=$!
    ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
    ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
    wait $SP $MP 2>/dev/null || true
    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    if [ "$b" != "0" ] && [ -n "$tx" ] && awk -v t="$tx" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then
      try=$((try+1)); [ $try -le 2 ] && continue
    fi
    break
  done
  printf "%-16s b=%-3s r%s | rx=%-6s loss=%-8s busy=%s\n" "$arm" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" | tee -a "$LOG/summary.txt"
}

for rep in $(seq 1 $REPS); do
  echo "===== REP $rep =====" | tee -a "$LOG/summary.txt"
  for b in 35 40 43 0; do
    point "DIMon_shedON"   1 1 "$b" "$rep"
    point "DIMoff_shedON"  0 1 "$b" "$rep"
    point "DIMoff_shedOFF" 0 0 "$b" "$rep"
    point "DIMon_shedOFF"  1 0 "$b" "$rep"
  done
  echo "" | tee -a "$LOG/summary.txt"
done
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 net.ipv4.udp_rx_shed=0 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
