#!/bin/bash
# baseline_confirm_1c.sh — 30s 확인 런, 진짜 단일코어(1c) 전용
# baseline_matrix.sh와 동일 방법론. fixed-rate CPU% 메트릭용 mpstat 포함.
set -u
TAG="${1:-vanilla30s}"
REPS="${2:-3}"
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/confirm_${TAG}_${TS}
mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238
IF=ens81f0np0
DUR=30

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG/run.log"; }

setup_receiver() {
  ssh sslab4 "
    sudo ip link set $IF mtu 9000
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
    sudo ethtool -L $IF combined 1 2>/dev/null || true
    sleep 2
    for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do
      echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true
    done
    sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=536870912 >/dev/null
    echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs >/dev/null
    echo 0 | sudo tee /sys/class/net/$IF/gro_flush_timeout >/dev/null
  " > "$LOG/setup_sslab4.log" 2>&1
  ssh sslab3 "sudo ip link set $IF mtu 9000; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done" >> "$LOG/setup_sslab4.log" 2>&1
}

verify_receiver() {
  ssh sslab4 "uname -r; systemctl is-active irqbalance; ethtool -l $IF | tail -1; for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do cat /proc/irq/\$irq/smp_affinity; done | sort | uniq -c; sysctl -n net.core.rmem_max; ip link show $IF | grep -o 'mtu [0-9]*'" | tee "$LOG/verify_sslab4.log"
}

run_point() {
  local name="$1" scmd="$2" ccmd="$3" dur="$4"
  local d="$LOG/$name"
  mkdir -p "$d"
  echo "server: $scmd" > "$d/meta.txt"; echo "client: $ccmd" >> "$d/meta.txt"
  ssh sslab4 "nstat -az | grep -E 'UdpRcvbufErrors|UdpInDatagrams'; sudo ethtool -S $IF | grep rx_out_of_buffer" > "$d/counters_before.txt" 2>&1
  ssh sslab4 "mpstat -P 1 1 $dur" > "$d/mpstat_sslab4.log" 2>&1 &
  local MP=$!
  ssh sslab4 "$scmd" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab3 "$ccmd" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP 2>/dev/null || true
  wait $MP 2>/dev/null || true
  ssh sslab4 "nstat -az | grep -E 'UdpRcvbufErrors|UdpInDatagrams'; sudo ethtool -S $IF | grep rx_out_of_buffer" > "$d/counters_after.txt" 2>&1
  local rxline usr1 sys1 soft1 idle1
  rxline=$(grep -E 'receiver' "$d/client.log" | tail -1)
  usr1=$(awk '$2==1 {u+=$3; n++} END {if(n)printf "%.0f", u/n}' "$d/mpstat_sslab4.log")
  sys1=$(awk '$2==1 {s+=$5; n++} END {if(n)printf "%.0f", s/n}' "$d/mpstat_sslab4.log")
  soft1=$(awk '$2==1 {s+=$8; n++} END {if(n)printf "%.0f", s/n}' "$d/mpstat_sslab4.log")
  idle1=$(awk '$2==1 {s+=$12; n++} END {if(n)printf "%.0f", s/n}' "$d/mpstat_sslab4.log")
  echo "$name | $rxline | c1 usr/sys/soft/idle=${usr1}/${sys1}/${soft1}/${idle1}" | tee -a "$LOG/summary.txt"
}

setup_receiver
verify_receiver
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = "9000" ] || { log "FATAL: $h MTU=$m"; exit 1; }
done

for rep in $(seq 1 "$REPS"); do
  log "===== REP $rep ====="
  run_point "r${rep}_tcp_1c" \
    "taskset -c 1 iperf3 -s -B $SRV_IP -1" \
    "taskset -c 1 iperf3 -c $SRV_IP -t $DUR" $DUR
  for b in 20 22 25; do
    run_point "r${rep}_udp_plain_1c_b${b}" \
      "IPERF3_UDP_GRO=0 taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 8972 -t $DUR" $DUR
  done
  for b in 28 30 32 35; do
    run_point "r${rep}_udp_gsogro_1c_b${b}" \
      "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" $DUR
  done
done

ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
log "DONE. Results: $LOG/summary.txt"
