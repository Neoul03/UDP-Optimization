#!/bin/bash
# verify_v21.sh — v21 이 의도대로 동작하는지 확인한다.
#
# 묻는 것 하나: 앱이 SO_RCVBUF 를 불러도 autotune 이 자라는가.
#   v20 에서는 SOCK_RCVBUF_LOCK 이 서면 udp_rcvbuf_autotune() 이 물러서서
#   sk_rcvbuf 가 425984 에 고정됐다 (측정 29.62 Gb/s).
#   v21 에서는 그 값이 **하한**이 되므로 그 위로 자라야 한다.
#
# 기대:
#   SO_RCVBUF 호출함   -> sk_rcvbuf 가 425984 보다 커지고 goodput 이 60 대
#   SO_RCVBUF 안 부름  -> 종전과 같이 자람 (회귀 없음 확인)
set -u
IF=ens81f0np0; SRV=192.168.11.238; P=5301
L=$(mktemp -d)

ssh sslab4 "uname -r; dmesg 2>/dev/null | grep -i 'receive budget' | tail -1"
# 단일코어 방법론 + 우리 기능 켜기
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "sudo ethtool -G $IF rx 128 >/dev/null 2>&1"; sleep 4
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1"
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"; sleep 3
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 67108864' net.core.rmem_max=212992 \
    net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null"

for mode in "UDP_SINK_RCVBUF=67108864" "UDP_SINK_NO_RCVBUF=1"; do
  ssh sslab4 "$mode taskset -c 1 /home/chanseo/udp_sink $SRV $P 2 9" > "$L/v.log" 2>&1 &
  sleep 1
  ssh sslab3 "taskset -c 1 timeout 11 /home/chanseo/udp_blast $SRV $P 8972 7 7 65" >/dev/null 2>&1 &
  sleep 4
  rb=$(ssh sslab4 "ss -uam 2>/dev/null | grep -A1 ':$P ' | grep -oE 'rb[0-9]+' | head -1")
  wait 2>/dev/null
  printf "%-28s  sk_rcvbuf=%-12s  goodput=%s\n" "$mode" "${rb:-?}" \
     "$(grep -oE 'goodput=[0-9.]+' "$L/v.log" | cut -d= -f2)"
done
rm -rf "$L"
echo "참고: v20 에서는 SO_RCVBUF 호출 시 rb425984 / 29.62, 미호출 시 rb3749760 / 61.42 였다."
