#!/bin/bash
# ab_earlydrop_1c.sh — 6.6.9-udprx1에서 early drop A/B (진짜 단일코어)
# arm E0: autotune on(cap512M) + ED off   (P3만 = 어제 C arm 재현)
# arm E1: autotune on(cap512M) + ED on    (P3+P2)
# arm F0: autotune off + 208K + ED off    (stock 재현)
# arm F1: autotune off + 208K + ED on     (P2 단독)
# 포커스: overrun/collapse 구간. mpstat %soft/%sys로 NAPI/consumer 배분 관찰.
set -u
REPS="${1:-2}"
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/ab_earlydrop_${TS}
mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238
IF=ens81f0np0
DUR=15

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG/run.log"; }

setup_receiver() {
  ssh sslab4 "
    sudo ip link set $IF mtu 9000
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
    sudo ethtool -L $IF combined 1 2>/dev/null || true
    sleep 2
    for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
    echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null
    sudo sysctl -w net.core.rmem_max=536870912 >/dev/null
  " > "$LOG/setup_sslab4.log" 2>&1
  ssh sslab3 "sudo ip link set $IF mtu 9000; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done" >> "$LOG/setup_sslab4.log" 2>&1
}

set_arm() {  # set_arm <autotune> <cap> <rmem_default> <early_drop>
  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=$1 net.ipv4.udp_rmem_autotune_max=$2 net.core.rmem_default=$3 net.ipv4.udp_early_drop=$4" | tee -a "$LOG/run.log"
}

run_point() {
  local name="$1" scmd="$2" ccmd="$3" dur="$4"
  local d="$LOG/$name"; mkdir -p "$d"
  ssh sslab4 "nstat -az | grep -E 'UdpRcvbufErrors|UdpInDatagrams'" > "$d/counters_before.txt" 2>&1
  ssh sslab4 "mpstat -P 1 1 $dur" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab4 "$scmd" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ( sleep $((dur/2)); ssh sslab4 "ss -uampi 'sport = 5201' 2>/dev/null | head -8" > "$d/ss_mid.txt" 2>&1 ) &
  local SSP=$!
  ssh sslab3 "$ccmd" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP $MP $SSP 2>/dev/null || true
  ssh sslab4 "nstat -az | grep -E 'UdpRcvbufErrors|UdpInDatagrams'" > "$d/counters_after.txt" 2>&1
  local rxline sys1 soft1 rb
  rxline=$(grep -E 'receiver' "$d/client.log" | tail -1)
  sys1=$(awk '$2==1 {s+=$5; n++} END {if(n)printf "%.0f", s/n}' "$d/mpstat.log")
  soft1=$(awk '$2==1 {s+=$8; n++} END {if(n)printf "%.0f", s/n}' "$d/mpstat.log")
  rb=$(grep -oE 'rb[0-9]+' "$d/ss_mid.txt" | head -1)
  echo "$name | $rxline | sys/soft=${sys1}/${soft1} $rb" | tee -a "$LOG/summary.txt"
}

run_arm() {
  local arm="$1" rep="$2"
  for b in 30 35 40 0; do   # 0 = unlimited blast
    local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
    run_point "${arm}_r${rep}_gsogro_b${b}" \
      "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" $DUR
  done
  for b in 22 25 30; do
    run_point "${arm}_r${rep}_plain_b${b}" \
      "IPERF3_UDP_GRO=0 taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 8972 -t $DUR" $DUR
  done
}

setup_receiver
ssh sslab4 "uname -r; sysctl net.ipv4.udp_early_drop 2>&1" | tee "$LOG/verify.log"
grep -q early_drop "$LOG/verify.log" || { log "FATAL: early_drop sysctl 없음"; exit 1; }
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = "9000" ] || { log "FATAL: $h MTU=$m"; exit 1; }
done

for rep in $(seq 1 "$REPS"); do
  log "===== REP $rep ====="
  log "--- E0: autotune on + ED off ---"; set_arm 1 536870912 212992 0; run_arm E0 $rep
  log "--- E1: autotune on + ED on ---";  set_arm 1 536870912 212992 1; run_arm E1 $rep
  log "--- F0: autotune off 208K + ED off ---"; set_arm 0 536870912 212992 0; run_arm F0 $rep
  log "--- F1: autotune off 208K + ED on ---";  set_arm 0 536870912 212992 1; run_arm F1 $rep
done

ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
log "DONE. Results: $LOG/summary.txt"
