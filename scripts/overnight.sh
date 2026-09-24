#!/bin/bash
# overnight.sh — 무인 실행 체인. 각 단계는 독립이고, 하나가 실패해도 다음으로 간다.
#
# 무인 실행의 위험은 한 스크립트가 NIC 설정을 바꿔놓고 죽는 것이다. 그러면
# 이후 모든 측정이 조용히 틀린 설정에서 돈다. 그래서 **매 단계 앞에서 기준
# 설정을 다시 세우고**, 끝나면 확인해서 로그에 남긴다.
set -u
OUT=~/lab/logs/overnight_$(date +%Y%m%d_%H%M%S); mkdir -p "$OUT"
IF=ens81f0np0
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }

baseline() {
  ssh sslab4 "sudo ip link set $IF mtu 9000" 2>/dev/null
  ssh sslab3 "sudo ip link set $IF mtu 9000" 2>/dev/null
  ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
  ssh sslab4 "sudo ethtool -G $IF rx 128 >/dev/null 2>&1"; sleep 3
  ssh sslab4 "for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done"
  ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1"
  ssh sslab4 "echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null"
  local st; st=$(ssh sslab4 "ip link show $IF | grep -o 'mtu [0-9]*'; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'; ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \"combined \" \$2; exit}'" | tr '\n' ' ')
  log "  baseline: $st"
}

idle() {  # 유휴가 될 때까지 기다린다. 이전 단계의 잔여 프로세스가 다음을 오염시킨다.
  local k=0
  while [ "$(ssh sslab4 'ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1' 2>/dev/null || echo 99)" -ge 5 ]; do
    sleep 30; k=$((k+1)); [ "$k" -gt 40 ] && { log "  WARN: 유휴 대기 20분 초과, 진행"; break; }
  done
}

step() {  # step <name> <cmd...>
  local name="$1"; shift
  log "=== $name 시작 ==="
  ssh sslab4 "pgrep -a udp_sink >/dev/null && pkill -f '[u]dp_sink'; true" 2>/dev/null
  ssh sslab3 "pgrep -a udp_blast >/dev/null && pkill -f '[u]dp_blast'; true" 2>/dev/null
  idle
  baseline
  if "$@" > "$OUT/$name.out" 2>&1; then log "=== $name 완료 ==="
  else log "=== $name 실패 (exit $?) - 다음으로 진행 ==="; fi
  tail -25 "$OUT/$name.out" >> "$OUT/run.log" 2>/dev/null || true
}

log "overnight 시작. 커널: $(ssh sslab4 uname -r)"

# 1. shed 한계 기여 (논문에 shed 를 넣을지 정하는 숫자)
step shed_marginal   bash ~/lab/scripts/ab_shed_marginal.sh 5
# 2. protocol isolation - autotune 켠 상태로 재측정
step protocol_iso    bash ~/lab/scripts/ab_protocol_isolation.sh 5 64
# 3. 앱이 UDP_GRO 를 안 켠 경우, 기본 설정(DIM on)에서
step gro_levers_on   bash ~/lab/scripts/ab_gro_levers.sh 3 on
# 4. 같은 것, DIM off
step gro_levers_off  bash ~/lab/scripts/ab_gro_levers.sh 3 off
# 5. 두 워크로드 N=10 - 논문 본표
step main_table      bash ~/lab/scripts/bench_two_workloads.sh 10
# 6. 다수 sender fan-in, GSO 유무
step fanin_gso       bash ~/lab/scripts/sweep_fanin.sh 3 40 7
step fanin_nogso     bash ~/lab/scripts/sweep_fanin.sh 3 30 1
# 7. 멀티코어 - ring/큐를 바꾸므로 **마지막에** 둔다
step multicore4      bash ~/lab/scripts/bench_multicore.sh 4 3 48

log "전부 종료. 설정 복원 중"
baseline
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null 2>&1"
ssh sslab4 "pgrep -a udp_sink || echo clean" | tee -a "$OUT/run.log"
log "DONE $OUT"
