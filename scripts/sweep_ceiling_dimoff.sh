#!/bin/bash
# sweep_ceiling_dimoff.sh — DIM off + shed off + 1.5MB 에서 진짜 천장 탐색
# 근거: b=43에서 43.0G@0% 3/3 결정적, busy 87% (미포화) → 더 올라갈 여지 있음
set -u
REPS="${1:-3}"; DUR="${2:-30}"; RATES="${3:-44 46 48 50 52}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/ceiling_dimoff_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0
ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/threaded >/dev/null 2>&1 || true
  echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null
  sudo ethtool -C $IF adaptive-rx off 2>/dev/null || true
  sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=1572864 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_early_drop=0 net.ipv4.udp_rx_shed=0 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1
ssh sslab4 "uname -r; ethtool -c $IF | grep -i 'adaptive rx'; sysctl -n net.core.rmem_default net.ipv4.udp_rx_shed" | tee "$LOG/verify.log"
for rep in $(seq 1 $REPS); do
 for b in $RATES; do
  try=0
  while : ; do
   d="$LOG/b${b}_r${rep}$([ $try -gt 0 ] && echo _t$try)"; mkdir -p "$d"
   ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & SP=$!
   sleep 2
   ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 & MP=$!
   ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
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
  eff=$(awk -v r="${rx:-0}" -v bu="${busy:-0}" 'BEGIN{if(bu>0)printf "%.3f", r/bu; else print "NA"}')
  printf "b=%-3s r%s | rx=%-6s loss=%-9s busy=%-4s eff=%-6s tx=%s\n" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "$eff" "${tx:-NA}" | tee -a "$LOG/summary.txt"
 done
done
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
