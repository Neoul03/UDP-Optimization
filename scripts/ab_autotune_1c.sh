#!/bin/bash
# ab_autotune_1c.sh — autotune 커널(6.6.9-autotune) 부팅 후 4-arm A/B (진짜 단일코어)
# arm A: autotune=0 + rmem_default 208KB  (stock 재현)
# arm B: autotune=0 + rmem_default 512MB  (수동 튜닝 = 기존 workaround)
# arm C: autotune=1 cap 512MB + rmem_default 208KB (제안 기법)
# arm D: autotune=1 cap 32MB(패치 default) + rmem_default 208KB
# 리부팅 불필요 — 전부 runtime sysctl 토글. 각 arm에서 gsogro/plain sweep + sk_rcvbuf 관찰.
set -u
REPS="${1:-2}"
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/ab_autotune_${TS}
mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238
IF=ens81f0np0
DUR=15

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG/run.log"; }

setup_receiver() {  # baseline과 동일 방법론 (rmem은 arm별로 설정하므로 제외)
  ssh sslab4 "
    sudo ip link set $IF mtu 9000
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
    sudo ethtool -L $IF combined 1 2>/dev/null || true
    sleep 2
    for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
    echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null
  " > "$LOG/setup_sslab4.log" 2>&1
  ssh sslab3 "sudo ip link set $IF mtu 9000; for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done" >> "$LOG/setup_sslab4.log" 2>&1
}

set_arm() {  # set_arm <autotune 0/1> <cap bytes> <rmem_default bytes>
  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=$1 net.ipv4.udp_rmem_autotune_max=$2 net.core.rmem_default=$3 net.core.rmem_max=536870912" | tee -a "$LOG/run.log"
}

run_point() {
  local name="$1" scmd="$2" ccmd="$3" dur="$4"
  local d="$LOG/$name"; mkdir -p "$d"
  ssh sslab4 "$scmd" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  # 측정 중반에 socket rcvbuf 실측 (autotune 성장 관찰)
  ( sleep $((dur/2)); ssh sslab4 "ss -uampi 'sport = 5201' 2>/dev/null | head -8" > "$d/ss_mid.txt" 2>&1 ) &
  local SSP=$!
  ssh sslab3 "$ccmd" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP $SSP 2>/dev/null || true
  local rxline rcvbuf
  rxline=$(grep -E 'receiver' "$d/client.log" | tail -1)
  rcvbuf=$(grep -oE 'skmem:\(r[0-9]+,rb[0-9]+' "$d/ss_mid.txt" | head -1)
  echo "$name | $rxline | $rcvbuf" | tee -a "$LOG/summary.txt"
}

run_arm() {  # run_arm <armname> <rep>
  local arm="$1" rep="$2"
  for b in 24 28 30 32; do
    run_point "${arm}_r${rep}_gsogro_b${b}" \
      "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" $DUR
  done
  for b in 20 22 25; do
    run_point "${arm}_r${rep}_plain_b${b}" \
      "IPERF3_UDP_GRO=0 taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 8972 -t $DUR" $DUR
  done
}

setup_receiver
ssh sslab4 "uname -r; sysctl net.ipv4.udp_rmem_autotune net.ipv4.udp_rmem_autotune_max 2>&1" | tee "$LOG/verify.log"
grep -q autotune "$LOG/verify.log" || { log "FATAL: autotune sysctl 없음 (커널이 6.6.9-autotune 아님?)"; exit 1; }
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = "9000" ] || { log "FATAL: $h MTU=$m"; exit 1; }
done

for rep in $(seq 1 "$REPS"); do
  log "===== REP $rep ====="
  log "--- arm A: autotune off, default 208KB (stock) ---"
  set_arm 0 33554432 212992;   run_arm A $rep
  log "--- arm B: autotune off, manual 512MB ---"
  set_arm 0 33554432 536870912; run_arm B $rep
  log "--- arm C: autotune on, cap 512MB, default 208KB ---"
  set_arm 1 536870912 212992;  run_arm C $rep
  log "--- arm D: autotune on, cap 32MB, default 208KB ---"
  set_arm 1 33554432 212992;   run_arm D $rep
done

ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
log "DONE. Results: $LOG/summary.txt"
