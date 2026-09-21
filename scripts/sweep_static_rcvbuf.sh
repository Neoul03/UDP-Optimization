#!/bin/bash
# sweep_static_rcvbuf.sh — Phase A: 정적 rcvbuf 최적점 정밀 스윕 (autotune OFF, shed ON)
# tx가 offered의 97% 미만이면 sender flake로 보고 최대 2회 재시도.
set -u
REPS="${1:-2}"; DUR="${2:-15}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/static_rcvbuf_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  sudo sysctl -w net.core.rmem_max=536870912 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=1 net.ipv4.udp_early_drop=0 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1
for h in sslab3 sslab4; do m=$(ssh $h "ip link show $IF"|grep -o 'mtu [0-9]*'|awk '{print $2}'); [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }; done
ssh sslab4 "uname -r; sysctl -n net.ipv4.udp_rx_shed net.ipv4.udp_rmem_autotune" | tee "$LOG/verify.log"

one_run() {  # one_run <dir> <bytes> <offered> ; echo "rx loss busy rb tx"
  local d="$1"; local bytes="$2"; local b="$3"
  mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes >/dev/null"
  local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ( sleep $((DUR/2)); ssh sslab4 "ss -uampi 'sport = 5201' 2>/dev/null | head -6" > "$d/ss.txt" 2>&1 ) &
  local SS=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP $MP $SS 2>/dev/null || true
}

point() {  # point <capname> <bytes> <offered>
  local capname="$1"; local bytes="$2"; local b="$3"; local rep="$4"
  local try=0 rx tx loss busy rb d
  while : ; do
    d="$LOG/${capname}_b${b}_r${rep}$([ $try -gt 0 ] && echo _retry$try)"
    one_run "$d" "$bytes" "$b"
    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    rb=$(grep -oE 'rb[0-9]+' "$d/ss.txt" 2>/dev/null|head -1)
    if [ "$b" != "0" ] && [ -n "$tx" ]; then
      if awk -v t="$tx" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then
        try=$((try+1)); [ $try -le 2 ] && { echo "   (flake tx=$tx < ${b}G, retry $try)" >> "$LOG/run.log"; continue; }
      fi
    fi
    break
  done
  printf "%-6s b=%-3s r%s | rx=%-6s loss=%-7s busy=%-4s tx=%-6s %s\n" "$capname" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "${tx:-NA}" "${rb:-}" | tee -a "$LOG/summary.txt"
}

CAPS="208K:212992 256K:262144 384K:393216 512K:524288 768K:786432 1M:1048576 1M5:1572864 2M:2097152 3M:3145728 4M:4194304 6M:6291456 8M:8388608"
for rep in $(seq 1 $REPS); do
  echo "===== REP $rep =====" | tee -a "$LOG/summary.txt"
  for b in 35 40 0; do
    for c in $CAPS; do
      point "${c%%:*}" "${c##*:}" "$b" "$rep"
    done
    echo "" | tee -a "$LOG/summary.txt"
  done
done
ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
