#!/bin/bash
# ablate_buffer_shed.sh — 핵심 2x2 ablation: 버퍼 크기 × shed
# 질문: 최적 버퍼(1.5MB)에서도 driver shed가 필요한가?
#   B15_S0 : 1.5MB static, shed off   ← 이 값이 관건
#   B15_S1 : 1.5MB static, shed on
#   B512_S0: 512MB static, shed off   (stock 튜닝 관행)
#   B512_S1: 512MB static, shed on
# 추가로 stock 208KB/shed off 를 기준선으로.
# autotune OFF (정적), 진짜 단일코어.
set -u
REPS="${1:-3}"; DUR="${2:-20}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/ablate_bufshed_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238; IF=ens81f0np0

ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null
  sudo sysctl -w net.core.rmem_max=536870912 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_early_drop=0 >/dev/null
  sudo sysctl -w net.ipv4.tcp_rmem='4096 131072 6291456' >/dev/null   # TCP 기본값 원복
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000; sudo sysctl -w net.ipv4.tcp_wmem='4096 16384 4194304' >/dev/null" >> "$LOG/setup.log" 2>&1
for h in sslab3 sslab4; do m=$(ssh $h "ip link show $IF"|grep -o 'mtu [0-9]*'|awk '{print $2}'); [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }; done
ssh sslab4 "uname -r; sysctl -n net.ipv4.udp_rx_shed net.ipv4.udp_rmem_autotune" | tee "$LOG/verify.log"

point() {  # point <armname> <rmem_bytes> <shed 0/1> <offered> <rep>
  local arm="$1"; local bytes="$2"; local shed="$3"; local b="$4"; local rep="$5"
  local try=0 rx tx loss busy d
  while : ; do
    d="$LOG/${arm}_b${b}_r${rep}$([ $try -gt 0 ] && echo _retry$try)"
    mkdir -p "$d"
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes net.ipv4.udp_rx_shed=$shed >/dev/null"
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
  printf "%-9s b=%-3s r%s | rx=%-6s loss=%-8s busy=%-4s tx=%s\n" "$arm" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "${tx:-NA}" | tee -a "$LOG/summary.txt"
}

for rep in $(seq 1 $REPS); do
  echo "===== REP $rep =====" | tee -a "$LOG/summary.txt"
  for b in 35 40 0; do
    point "B15_S0"   1572864   0 "$b" "$rep"    # ★ 관건: 최적 버퍼, shed 없음
    point "B15_S1"   1572864   1 "$b" "$rep"
    point "B512_S0"  536870912 0 "$b" "$rep"
    point "B512_S1"  536870912 1 "$b" "$rep"
    point "B208K_S0" 212992    0 "$b" "$rep"    # stock 기준선
    echo "" | tee -a "$LOG/summary.txt"
  done
done
ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 net.ipv4.udp_rx_shed=0 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
