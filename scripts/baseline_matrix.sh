#!/bin/bash
# baseline_matrix.sh — Phase 1 baseline 재확정 (진짜 단일코어 방법론)
# 260609 확정 방법론: irqbalance masked + combined=1 + msi_irqs 전부 core1 + governor performance
# + mpstat %soft 검증. server=sslab4(RX), client=sslab3(TX).
# Usage: baseline_matrix.sh <tag> [reps]   (tag 예: vanilla, nohardened)
set -u
TAG="${1:?usage: baseline_matrix.sh <tag> [reps]}"
REPS="${2:-3}"
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/baseline_${TAG}_${TS}
mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238
IF=ens81f0np0
DUR=10

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG/run.log"; }

# ---------- 셋업 (sslab4 RX) ----------
setup_receiver() {
  ssh sslab4 "
    set -x
    # MTU 9000 (리부팅 시 1500으로 리셋됨 — 반드시 재설정)
    sudo ip link set $IF mtu 9000
    # governor performance (전체 코어)
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
    # RSS 제거: RX 큐 1개
    sudo ethtool -L $IF combined 1 2>&1 | grep -v '^$' || true
    sleep 2
    # NIC msi IRQ 전부 core1 (mask 0x2) — combined 변경 후 재핀 필수
    for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do
      echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true
    done
    # rmem 512MB
    sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=536870912
    # NAPI knob baseline (0/0)
    echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs >/dev/null
    echo 0 | sudo tee /sys/class/net/$IF/gro_flush_timeout >/dev/null
  " > "$LOG/setup_sslab4.log" 2>&1
  ssh sslab3 "
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  " > "$LOG/setup_sslab3.log" 2>&1
}

verify_receiver() {
  ssh sslab4 "
    echo '== kernel ==' ; uname -r
    echo '== irqbalance ==' ; systemctl is-active irqbalance
    echo '== combined ==' ; ethtool -l $IF | tail -2
    echo '== irq affinity ==' ; for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do cat /proc/irq/\$irq/smp_affinity; done | sort | uniq -c
    echo '== rmem ==' ; sysctl net.core.rmem_max
    echo '== governor ==' ; cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor
    echo '== gro ==' ; ethtool -k $IF | grep -E 'generic-receive-offload|rx-gro-list'
    echo '== mtu ==' ; ip link show $IF | grep -o 'mtu [0-9]*'
  " | tee "$LOG/verify_sslab4.log"
}

# ---------- 측정 1점 ----------
# run_point <name> <server_cmd> <client_cmd> <dur>
run_point() {
  local name="$1" scmd="$2" ccmd="$3" dur="$4"
  local d="$LOG/$name"
  mkdir -p "$d"
  echo "server: $scmd" > "$d/meta.txt"
  echo "client: $ccmd" >> "$d/meta.txt"
  # 카운터 snapshot (before)
  ssh sslab4 "nstat -az | grep -E 'UdpRcvbufErrors|UdpInDatagrams|UdpInErrors'; sudo ethtool -S $IF | grep -E 'rx_out_of_buffer'" > "$d/counters_before.txt" 2>&1
  # mpstat (sslab4, 측정 중)
  ssh sslab4 "mpstat -P 1,3 1 $dur" > "$d/mpstat_sslab4.log" 2>&1 &
  local MP=$!
  # server
  ssh sslab4 "$scmd" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  # client
  ssh sslab3 "$ccmd" > "$d/client.log" 2>&1 || true
  # cleanup
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
  wait $SP 2>/dev/null || true
  wait $MP 2>/dev/null || true
  ssh sslab4 "nstat -az | grep -E 'UdpRcvbufErrors|UdpInDatagrams|UdpInErrors'; sudo ethtool -S $IF | grep -E 'rx_out_of_buffer'" > "$d/counters_after.txt" 2>&1
  # 요약 추출
  local rxline loss soft1 sys1 soft3 sys3
  rxline=$(grep -E 'receiver' "$d/client.log" | tail -1)
  soft1=$(awk '$2==1 {sum+=$8; n++} END {if(n)printf "%.0f", sum/n}' "$d/mpstat_sslab4.log")
  sys1=$(awk '$2==1 {sum+=$5; n++} END {if(n)printf "%.0f", sum/n}' "$d/mpstat_sslab4.log")
  soft3=$(awk '$2==3 {sum+=$8; n++} END {if(n)printf "%.0f", sum/n}' "$d/mpstat_sslab4.log")
  sys3=$(awk '$2==3 {sum+=$5; n++} END {if(n)printf "%.0f", sum/n}' "$d/mpstat_sslab4.log")
  echo "$name | $rxline | c1 soft/sys=${soft1}/${sys1} c3 soft/sys=${soft3}/${sys3}" | tee -a "$LOG/summary.txt"
}

# ---------- 매트릭스 ----------
setup_receiver
verify_receiver

# MTU assert — 9000 아니면 전체 무효이므로 중단
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  if [ "$m" != "9000" ]; then log "FATAL: $h MTU=$m (need 9000). Abort."; exit 1; fi
done

for rep in $(seq 1 "$REPS"); do
  log "===== REP $rep ====="

  # TCP 1-core (stock iperf3): NAPI+consumer 모두 core1
  run_point "r${rep}_tcp_1c" \
    "taskset -c 1 iperf3 -s -B $SRV_IP -1" \
    "taskset -c 1 iperf3 -c $SRV_IP -t $DUR" $DUR

  # TCP 2-core: consumer core3
  run_point "r${rep}_tcp_2c" \
    "taskset -c 3 iperf3 -s -B $SRV_IP -1" \
    "taskset -c 1 iperf3 -c $SRV_IP -t $DUR" $DUR

  # UDP plain (-l 8972, GRO off) 1-core sweep
  for b in 15 20 22 25 28; do
    run_point "r${rep}_udp_plain_1c_b${b}" \
      "IPERF3_UDP_GRO=0 taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 8972 -t $DUR" $DUR
  done

  # UDP GSO+GRO (-l 65000, GRO on) 1-core sweep
  for b in 20 24 26 28 30 32; do
    run_point "r${rep}_udp_gsogro_1c_b${b}" \
      "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" $DUR
  done

  # UDP plain 2-core sweep (consumer c3)
  for b in 20 25 28 30; do
    run_point "r${rep}_udp_plain_2c_b${b}" \
      "IPERF3_UDP_GRO=0 taskset -c 3 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 8972 -t $DUR" $DUR
  done

  # UDP GSO+GRO 2-core sweep
  for b in 30 35 40 45; do
    run_point "r${rep}_udp_gsogro_2c_b${b}" \
      "taskset -c 3 $IPERF_MOD -s -B $SRV_IP -1" \
      "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" $DUR
  done

  # overrun 카운터 포인트: 1c gsogro -b35 (드롭 위치 확인용)
  run_point "r${rep}_udp_gsogro_1c_b35_overrun" \
    "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" \
    "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b 35G -l 65000 -t $DUR" $DUR
done

# cleanup 확인
ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/run.log"
log "DONE. Results: $LOG/summary.txt"
