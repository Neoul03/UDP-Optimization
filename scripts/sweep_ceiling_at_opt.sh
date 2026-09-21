#!/bin/bash
# sweep_ceiling_at_opt.sh — Phase B: 최적 정적 버퍼에서 rate를 올려 CPU 포화점/무손실 한계 탐색
# 진짜 단일코어. autotune OFF (정적), shed ON. sender flake 자동 재시도.
set -u
REPS="${1:-2}"; DUR="${2:-30}"
CAPS="${3:-1M5:1572864 2M:2097152 3M:3145728}"
RATES="${4:-38 40 42 44 46}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/ceiling_opt_${TS}; mkdir -p "$LOG"
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

one_run() {
  local d="$1"; local bytes="$2"; local b="$3"
  mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes >/dev/null"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true
}

point() {
  local capname="$1"; local bytes="$2"; local b="$3"; local rep="$4"
  local try=0 rx tx loss busy d eff
  while : ; do
    d="$LOG/${capname}_b${b}_r${rep}$([ $try -gt 0 ] && echo _retry$try)"
    one_run "$d" "$bytes" "$b"
    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    if [ -n "$tx" ] && awk -v t="$tx" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then
      try=$((try+1)); [ $try -le 2 ] && { echo "   (flake tx=$tx, retry $try)" >> "$LOG/run.log"; continue; }
    fi
    break
  done
  eff=$(awk -v r="${rx:-0}" -v bu="${busy:-0}" 'BEGIN{if(bu>0) printf "%.3f", r/bu; else print "NA"}')
  printf "%-4s b=%-3s r%s | rx=%-6s loss=%-8s busy=%-4s eff=%-6s tx=%s\n" \
    "$capname" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "$eff" "${tx:-NA}" | tee -a "$LOG/summary.txt"
}

for rep in $(seq 1 $REPS); do
  echo "===== REP $rep =====" | tee -a "$LOG/summary.txt"
  for c in $CAPS; do
    for b in $RATES; do
      point "${c%%:*}" "${c##*:}" "$b" "$rep"
    done
    echo "" | tee -a "$LOG/summary.txt"
  done
done
ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
