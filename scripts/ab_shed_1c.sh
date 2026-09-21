#!/bin/bash
# ab_shed_1c.sh — 6.6.9-udprx2 driver-level RX shed A/B (진짜 단일코어)
# 공통: autotune on cap512M, rmem_default 208K
# G0: ED off + shed off (reference = P3만)
# G1: ED on  + shed on  (P3+P2v1+P2v2 풀스택)
# G2: ED off + shed on  (shed는 enqueue-failure에서만 마킹 — v2 단독 ablation)
set -u
REPS="${1:-2}"
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/ab_shed_${TS}
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
    sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=212992 net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=536870912 >/dev/null
  " > "$LOG/setup_sslab4.log" 2>&1
  ssh sslab3 "sudo ip link set $IF mtu 9000; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done" >> "$LOG/setup_sslab4.log" 2>&1
}

set_arm() {  # set_arm <early_drop> <rx_shed>
  ssh sslab4 "sudo sysctl -w net.ipv4.udp_early_drop=$1 net.ipv4.udp_rx_shed=$2" | tee -a "$LOG/run.log"
}

run_point() {
  local name="$1" scmd="$2" ccmd="$3" dur="$4"
  local d="$LOG/$name"; mkdir -p "$d"
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
  local rxline sys1 soft1 rb sline
  rxline=$(grep -E 'receiver' "$d/client.log" | tail -1)
  sline=$(grep -E 'sender' "$d/client.log" | tail -1 | grep -oE '[0-9.]+ Gbits/sec' | head -1)
  sys1=$(awk '$2==1 {s+=$5; n++} END {if(n)printf "%.0f", s/n}' "$d/mpstat.log")
  soft1=$(awk '$2==1 {s+=$8; n++} END {if(n)printf "%.0f", s/n}' "$d/mpstat.log")
  rb=$(grep -oE 'rb[0-9]+' "$d/ss_mid.txt" | head -1)
  echo "$name | $rxline | tx=$sline sys/soft=${sys1}/${soft1} $rb" | tee -a "$LOG/summary.txt"
}

run_arm() {
  local arm="$1" rep="$2"
  for b in 32 35 40 0; do
    local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
    run_point "${arm}_r${rep}_gsogro_b${b}" \
      "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" $DUR
  done
  for b in 25 28; do
    run_point "${arm}_r${rep}_plain_b${b}" \
      "IPERF3_UDP_GRO=0 taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 8972 -t $DUR" $DUR
  done
}

setup_receiver
ssh sslab4 "uname -r; sysctl net.ipv4.udp_rx_shed 2>&1" | tee "$LOG/verify.log"
grep -q rx_shed "$LOG/verify.log" || { log "FATAL: rx_shed sysctl 없음"; exit 1; }
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = "9000" ] || { log "FATAL: $h MTU=$m"; exit 1; }
done

for rep in $(seq 1 "$REPS"); do
  log "===== REP $rep ====="
  log "--- G0: ED off, shed off ---"; set_arm 0 0; run_arm G0 $rep
  log "--- G1: ED on,  shed on  ---"; set_arm 1 1; run_arm G1 $rep
  log "--- G2: ED off, shed on  ---"; set_arm 0 1; run_arm G2 $rep
done

ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
log "DONE. Results: $LOG/summary.txt"
