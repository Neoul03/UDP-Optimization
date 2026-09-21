#!/bin/bash
# sweep_tcp_fairness.sh — TCP baseline의 "최적 조건"을 찾는다 (UDP와 공정 비교용)
# UDP는 -l 65000으로 튜닝했는데 TCP는 기본값이었으므로, TCP도 동일하게 튜닝해 최고치를 구한다.
# 동일 바이너리(수정판 3.20, TCP 경로는 미수정) 사용 — 버전 confound 제거.
# 진짜 단일코어.
set -u
REPS="${1:-3}"; DUR="${2:-30}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/tcp_fairness_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238; IF=ens81f0np0

ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  sudo sysctl -w net.core.rmem_max=536870912 net.ipv4.tcp_rmem='4096 131072 536870912' >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000; sudo sysctl -w net.core.wmem_max=536870912 net.ipv4.tcp_wmem='4096 65536 536870912' >/dev/null" >> "$LOG/setup.log" 2>&1
for h in sslab3 sslab4; do m=$(ssh $h "ip link show $IF"|grep -o 'mtu [0-9]*'|awk '{print $2}'); [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }; done
ssh sslab4 "uname -r; ethtool -k $IF | grep -E '^(generic-receive|large-receive)'" | tee "$LOG/verify.log"

# arm <name> <server_bin> <client_extra_opts>
arm() {
  local name="$1"; local sbin="$2"; local copts="$3"; local rep="$4"
  local d="$LOG/${name}_r${rep}"; mkdir -p "$d"
  ssh sslab4 "taskset -c 1 $sbin -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $sbin -c $SRV_IP -t $DUR $copts" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true
  local rx busy retr eff
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  retr=$(grep sender "$d/client.log"|tail -1|awk '{print $(NF-1)}')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  eff=$(awk -v r="${rx:-0}" -v b="${busy:-0}" 'BEGIN{if(b>0) printf "%.3f", r/b; else print "NA"}')
  printf "%-16s r%s | rx=%-6s busy=%-4s eff=%-6s retr=%s\n" "$name" "$rep" "${rx:-NA}" "${busy:-NA}%" "$eff" "${retr:-NA}" | tee -a "$LOG/summary.txt"
}

for rep in $(seq 1 $REPS); do
  echo "===== REP $rep =====" | tee -a "$LOG/summary.txt"
  # 기존 baseline 재현 (시스템 3.19 바이너리, 무튜닝)
  arm "sys319_default"   "iperf3"      ""                  "$rep"
  # 동일 바이너리(3.20)로 버전 confound 제거
  arm "v320_default"     "$IPERF_MOD"  ""                  "$rep"
  # TCP 튜닝 arm들
  arm "v320_l1M"         "$IPERF_MOD"  "-l 1M"             "$rep"
  arm "v320_l256K"       "$IPERF_MOD"  "-l 256K"           "$rep"
  arm "v320_Z"           "$IPERF_MOD"  "-Z"                "$rep"
  arm "v320_l1M_Z"       "$IPERF_MOD"  "-l 1M -Z"          "$rep"
  arm "v320_l1M_w64M"    "$IPERF_MOD"  "-l 1M -w 64M"      "$rep"
  echo "" | tee -a "$LOG/summary.txt"
done
ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
