#!/bin/bash
# Usage: set_dim.sh {on|off-pure|off-extreme} [host=sslab4] [iface=ens102f0np0]
# - on          : Adaptive RX/TX on, rx-usecs 50, GRO on, backlog 200k (= optimize_udp_interrupts.sh 모드 5)
# - off-pure    : Adaptive RX/TX off ONLY (GRO/buffer/budget은 원복값 유지) — DIM 변수 분리용
# - off-extreme : 모드 3 = rx-usecs 0, rx-frames 1, GRO off (+flush_timeout 0, batch 1),
#                 backlog 500k, budget 5000 (= 우리 baseline의 "Adaptive Off")
set -e
MODE="${1:?usage: set_dim.sh on or off-pure or off-extreme}"
HOST="${2:-sslab4}"
IFACE="${3:-ens81f0np0}"

run() { ssh "$HOST" "sudo bash -c '$*'"; }

apply_on() {
  run "ethtool -C $IFACE adaptive-rx on adaptive-tx on || true"
  run "ethtool -C $IFACE rx-usecs 50 tx-usecs 50 || true"
  run "ethtool -K $IFACE gro on rx-udp-gro-forwarding on || true"
  run "sysctl -w net.core.netdev_max_backlog=200000 net.core.netdev_budget=2000 net.core.netdev_budget_usecs=50000 net.core.gro_normal_batch=8"
  run "echo 20000 > /sys/class/net/$IFACE/gro_flush_timeout || true"
}

apply_off_pure() {
  # DIM만 끔. 나머지는 'on' 상태와 동일.
  run "ethtool -C $IFACE adaptive-rx off adaptive-tx off || true"
  run "ethtool -C $IFACE rx-usecs 50 tx-usecs 50 || true"
  run "ethtool -K $IFACE gro on rx-udp-gro-forwarding on || true"
  run "sysctl -w net.core.netdev_max_backlog=200000 net.core.netdev_budget=2000 net.core.netdev_budget_usecs=50000 net.core.gro_normal_batch=8"
  run "echo 20000 > /sys/class/net/$IFACE/gro_flush_timeout || true"
}

apply_off_extreme() {
  # optimize_udp_interrupts.sh 모드 3과 동일
  run "ethtool -C $IFACE adaptive-rx off adaptive-tx off || true"
  run "ethtool -C $IFACE rx-usecs 0 rx-frames 1 tx-usecs 0 tx-frames 8 || true"
  run "ethtool -K $IFACE gro off rx-udp-gro-forwarding off || true"
  run "sysctl -w net.core.netdev_max_backlog=500000 net.core.netdev_budget=5000 net.core.netdev_budget_usecs=100000 net.core.gro_normal_batch=1"
  run "echo 0 > /sys/class/net/$IFACE/gro_flush_timeout || true"
}

case "$MODE" in
  on)          apply_on ;;
  off-pure)    apply_off_pure ;;
  off-extreme) apply_off_extreme ;;
  *) echo "unknown mode: $MODE"; exit 1 ;;
esac

echo "=== applied: $MODE on $HOST/$IFACE ==="
ssh "$HOST" "ethtool -c $IFACE | grep -E 'Adaptive|rx-usecs|rx-frames'; ethtool -k $IFACE | grep -E '^gro|udp-gro'; sysctl net.core.netdev_max_backlog net.core.netdev_budget net.core.gro_normal_batch; cat /sys/class/net/$IFACE/gro_flush_timeout"
