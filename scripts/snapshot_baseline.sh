#!/bin/bash
# Usage: snapshot_baseline.sh [iface_sslab3] [iface_sslab4]
# sslab4 = receiver, sslab3 = sender
IFACE3=${1:-ens102f0np0}
IFACE4=${2:-ens102f0np0}
OUT=~/lab/configs/baseline_$(date +%Y%m%d_%H%M%S)
mkdir -p $OUT

for HOST_IFACE in "sslab4:$IFACE4" "sslab3:$IFACE3"; do
  HOST=${HOST_IFACE%:*}
  IFACE=${HOST_IFACE#*:}
  ROLE=$([ "$HOST" = "sslab4" ] && echo "receiver" || echo "sender")
  echo "[*] $HOST ($ROLE, $IFACE)"
  ssh $HOST "sudo ethtool -k $IFACE"        > $OUT/${HOST}_${ROLE}_ethtool_k.txt 2>&1
  ssh $HOST "sudo ethtool -c $IFACE"        > $OUT/${HOST}_${ROLE}_ethtool_c.txt 2>&1
  ssh $HOST "sudo ethtool -g $IFACE"        > $OUT/${HOST}_${ROLE}_ethtool_g.txt 2>&1
  ssh $HOST "sudo ethtool -S $IFACE"        > $OUT/${HOST}_${ROLE}_ethtool_S.txt 2>&1
  ssh $HOST "sysctl -a 2>/dev/null | grep -E 'net\.core|net\.ipv4\.udp'" \
                                            > $OUT/${HOST}_${ROLE}_sysctl.txt
done
echo "Baseline saved to $OUT"
