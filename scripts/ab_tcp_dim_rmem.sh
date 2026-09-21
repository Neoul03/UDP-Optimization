#!/bin/bash
# ab_tcp_dim_rmem.sh — Tier1 #2: TCP baseline 확정 + "큰 버퍼가 TCP도 느리게 하나" 교차검증
# 축1: DIM(adaptive-rx) on/off   축2: tcp_rmem 상한 6MB(기본) / 512MB
# UDP에서 발견한 "버퍼가 크면 캐시 파괴로 느려진다"가 TCP에서도 성립하는지 본다.
set -u
REPS="${1:-3}"; DUR="${2:-30}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/tcp_dim_rmem_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238; IF=ens81f0np0
PERF=/usr/lib/linux-tools/6.6.9/perf

ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/threaded >/dev/null 2>&1 || true
  sudo sysctl -w net.core.rmem_max=536870912 net.ipv4.tcp_moderate_rcvbuf=1 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1
for h in sslab3 sslab4; do m=$(ssh $h "ip link show $IF"|grep -o 'mtu [0-9]*'|awk '{print $2}'); [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }; done

point() {  # point <arm> <dim 0/1> <rmem_max_bytes> <rep>
  local arm="$1"; local dim="$2"; local rmax="$3"; local rep="$4"
  local d="$LOG/${arm}_r${rep}"; mkdir -p "$d"
  ssh sslab4 "
    sudo ethtool -C $IF adaptive-rx $([ $dim = 1 ] && echo on || echo off) 2>/dev/null || true
    sudo sysctl -w net.ipv4.tcp_rmem='4096 131072 $rmax' >/dev/null
  " >> "$LOG/run.log" 2>&1
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ( sleep 6; ssh sslab4 "sudo $PERF stat -C 1 -e cycles,instructions,cache-references,cache-misses -- sleep 10" > "$d/perf.txt" 2>&1 ) &
  local PF=$!
  ( sleep $((DUR/2)); ssh sslab4 "ss -tmi 'sport = 5201' 2>/dev/null | head -6" > "$d/ss.txt" 2>&1 ) &
  local SS=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP $MP $PF $SS 2>/dev/null || true
  local rx busy retr rb ipc miss
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  retr=$(grep sender "$d/client.log"|tail -1|awk '{print $(NF-1)}')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  rb=$(grep -oE 'rb[0-9]+' "$d/ss.txt" 2>/dev/null|head -1)
  ipc=$(grep -oE '[0-9.]+  insn per cycle' "$d/perf.txt" 2>/dev/null|head -1|awk '{print $1}')
  miss=$(grep -oE '[0-9.]+ % of all cache refs' "$d/perf.txt" 2>/dev/null|head -1|awk '{print $1}')
  printf "%-14s r%s | rx=%-6s busy=%-4s retr=%-6s ipc=%-5s miss=%-6s %s\n" \
    "$arm" "$rep" "${rx:-NA}" "${busy:-NA}%" "${retr:-NA}" "${ipc:-NA}" "${miss:-NA}%" "${rb:-}" | tee -a "$LOG/summary.txt"
}

for rep in $(seq 1 $REPS); do
  echo "===== REP $rep =====" | tee -a "$LOG/summary.txt"
  point "DIMon_6M"    1 6291456   "$rep"   # ★ 표준 구성 — 36.5G 재현 확인
  point "DIMoff_6M"   0 6291456   "$rep"   # DIM 자체 기여
  point "DIMon_512M"  1 536870912 "$rep"   # ★ 큰 버퍼가 TCP도 느리게 하나
  point "DIMoff_512M" 0 536870912 "$rep"
  echo "" | tee -a "$LOG/summary.txt"
done
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.ipv4.tcp_rmem='4096 131072 6291456' >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
