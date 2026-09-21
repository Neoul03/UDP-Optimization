#!/bin/bash
# Usage: run_dim_cycle.sh <mode> [dur_sec=30]
# mode: on | off-pure | off-extreme
# 한 사이클: 모드 설정 → iperf3 UDP 부하 → 동시 측정 (bpftrace + ss + nstat delta + IRQ delta)
set -e
MODE="${1:?usage: run_dim_cycle.sh mode [dur]}"
DUR="${2:-30}"
TS=$(date +%Y%m%d_%H%M%S)
OUT=~/lab/reports/cycle_${MODE}_${TS}
mkdir -p "$OUT"

RX_HOST=sslab4              # receiver
TX_HOST=sslab3              # sender
RX_IP=192.168.11.238        # CX5 ens81f0np0
IFACE=ens81f0np0            # mlx5_core
RX_CPU=1
TX_CPU=1
BITRATE="${BITRATE:-40G}"   # 사용자 baseline
IPERF=~/iperf3-source/src/iperf3   # GSO 지원 수정판 (양쪽 동일 경로)
LEN_OPT="${LEN_OPT:-}"      # 비우면 iperf3 default (UDP 1472). "-l 9000" 등으로 override
EXTRA_C="${EXTRA_C:-}"      # 추가 client 옵션 (e.g. --udp-segment 8192 등)

echo "[cycle] mode=$MODE dur=${DUR}s out=$OUT" | tee "$OUT/meta.txt"

# 0. 모드 설정
~/lab/scripts/set_dim.sh "$MODE" "$RX_HOST" "$IFACE" > "$OUT/dim_state.txt" 2>&1

# 1. 사전 cleanup
ssh $RX_HOST "pkill -9 iperf3 2>/dev/null; pkill -9 bpftrace 2>/dev/null; true"
ssh $TX_HOST "pkill -9 iperf3 2>/dev/null; true"
sleep 1

# 2. nstat baseline (receiver)
ssh $RX_HOST "nstat -az 2>/dev/null | grep -iE 'udp|drop'" > "$OUT/nstat_pre.txt"

# 3. IRQ baseline (receiver, mlx5 NIC IRQs)
ssh $RX_HOST "grep -E 'mlx5|$IFACE' /proc/interrupts" > "$OUT/irq_pre.txt"

# 4. iperf3 server (receiver) background — GSO 지원 binary
ssh $RX_HOST "taskset -c $RX_CPU $IPERF -s -B $RX_IP -A $RX_CPU -1" > "$OUT/server.log" 2>&1 &
SPID=$!
sleep 2

# 5. bpftrace (receiver) — tracepoint 기반 (bpftrace 0.9.4 BTF 미흡)
BPF_SCRIPT='
tracepoint:napi:napi_poll { @napi_work = hist(args->work); @napi_calls = count(); }
tracepoint:udp:udp_fail_queue_rcv_skb { @udp_drops = count(); }
'
ssh $RX_HOST "sudo timeout $((DUR+2)) bpftrace -e '$BPF_SCRIPT'" > "$OUT/bpf.txt" 2>&1 &
BPID=$!

# 5b. NIC counters (drop/byte/packet 모두) baseline — receiver + sender
ssh $RX_HOST "ethtool -S $IFACE" > "$OUT/ethtool_S_rx_pre.txt"
ssh $TX_HOST "ethtool -S $IFACE" > "$OUT/ethtool_S_tx_pre.txt"
ssh $RX_HOST "cat /proc/net/softnet_stat" > "$OUT/softnet_pre.txt"

# 6. ss -uem 시계열 (receiver, 0.5s 주기) — 5201 포트 매칭 다양화
ssh $RX_HOST "for i in \$(seq 1 $((DUR*2))); do echo \"--- t=\$i ---\"; sudo ss -uemnl 'sport = :5201'; sleep 0.5; done" > "$OUT/ss_uem.txt" 2>&1 &
SSPID=$!

# 7. iperf3 client (sender) — bitrate/length는 환경변수로 가변
ssh $TX_HOST "taskset -c $TX_CPU $IPERF -c $RX_IP -u $LEN_OPT -b $BITRATE -Z -A $TX_CPU -t $DUR $EXTRA_C" > "$OUT/client.log" 2>&1 || true

# 8. wait & cleanup
sleep 2
ssh $RX_HOST "pkill -9 iperf3 2>/dev/null; pkill -INT bpftrace 2>/dev/null; true"
wait $BPID 2>/dev/null || true
wait $SSPID 2>/dev/null || true
wait $SPID 2>/dev/null || true

# 9. nstat post + IRQ post + ethtool post + softnet post + delta
ssh $RX_HOST "nstat -az 2>/dev/null | grep -iE 'udp|drop'" > "$OUT/nstat_post.txt"
ssh $RX_HOST "grep -E 'mlx5|$IFACE' /proc/interrupts" > "$OUT/irq_post.txt"
ssh $RX_HOST "ethtool -S $IFACE" > "$OUT/ethtool_S_rx_post.txt"
ssh $TX_HOST "ethtool -S $IFACE" > "$OUT/ethtool_S_tx_post.txt"
ssh $RX_HOST "cat /proc/net/softnet_stat" > "$OUT/softnet_post.txt"

# 10. 요약 (control node에서 계산)
python3 - <<PYEOF > "$OUT/summary.txt"
import re

def parse_nstat(p):
    d = {}
    for line in open(p):
        parts = line.split()
        if len(parts) >= 2 and parts[1].isdigit():
            d[parts[0]] = int(parts[1])
    return d

pre = parse_nstat("$OUT/nstat_pre.txt")
post = parse_nstat("$OUT/nstat_post.txt")
keys = ['UdpInDatagrams','UdpInErrors','UdpRcvbufErrors','UdpNoPorts','IpExtInOctets','UdpIgnoredMulti','IpExtInNoRoutes','IpInReceives','IpInDelivers','IpInDiscards']
print("== nstat delta ($DUR s) ==")
for k in keys:
    if k in pre or k in post:
        d = post.get(k,0) - pre.get(k,0)
        print(f"  {k}: {d}  ({d/$DUR:.0f}/s)")

# ethtool -S delta (NIC level drops)
def parse_ethtool(p):
    d = {}
    for line in open(p):
        line = line.strip()
        if ':' in line:
            k, v = line.split(':', 1)
            v = v.strip()
            if v.isdigit():
                d[k.strip()] = int(v)
    return d
for side, pre_f, post_f in [
    ("RX(sslab4)", "$OUT/ethtool_S_rx_pre.txt", "$OUT/ethtool_S_rx_post.txt"),
    ("TX(sslab3)", "$OUT/ethtool_S_tx_pre.txt", "$OUT/ethtool_S_tx_post.txt"),
]:
    ethpre = parse_ethtool(pre_f)
    ethpost = parse_ethtool(post_f)
    print(f"== ethtool -S delta [{side}] ==")
    interesting = ('rx_packets','rx_bytes','rx_dropped','rx_out_of_buffer','rx_cache_full','rx_csum_complete',
                   'tx_packets','tx_bytes','tx_dropped','tx_queue_dropped','tx_xmit_more')
    for k in sorted(set(ethpre)|set(ethpost)):
        if any(s in k for s in interesting) or 'drop' in k.lower() or 'discard' in k.lower():
            d = ethpost.get(k,0) - ethpre.get(k,0)
            if d != 0:
                rate = d/$DUR
                if 'bytes' in k:
                    print(f"  {k}: {d}  ({rate/1e9:.2f} GB/s, {rate*8/1e9:.2f} Gbps)")
                else:
                    print(f"  {k}: {d}  ({rate:.0f}/s)")

# softnet_stat delta (cpu 1만 보기 — pinned)
def parse_softnet(p):
    rows = []
    for line in open(p):
        cols = line.split()
        if len(cols) >= 3:
            rows.append([int(c, 16) for c in cols])
    return rows
spre = parse_softnet("$OUT/softnet_pre.txt")
spost = parse_softnet("$OUT/softnet_post.txt")
print("== softnet_stat delta (CPU1: total_pkts, dropped, time_squeezed) ==")
if len(spre) > 1 and len(spost) > 1:
    cpu = 1
    if cpu < len(spre):
        a, b = spre[cpu], spost[cpu]
        # cols: processed, dropped, time_squeezed, cpu_collision, received_rps, flow_limit_count
        print(f"  CPU{cpu}: processed={b[0]-a[0]}, dropped={b[1]-a[1]}, time_squeezed={b[2]-a[2]}")

# IRQ delta
def parse_irq(p):
    d = {}
    for line in open(p):
        m = re.match(r'\s*(\d+):\s+(.*?)\s+[A-Z]', line)
        if m:
            irq = m.group(1)
            counts = [int(x) for x in m.group(2).split() if x.isdigit()]
            d[irq] = sum(counts)
    return d

irq_pre = parse_irq("$OUT/irq_pre.txt")
irq_post = parse_irq("$OUT/irq_post.txt")
total_delta = sum(irq_post.get(k,0) - irq_pre.get(k,0) for k in irq_post)
print(f"== IRQ delta (mlx5/{'$IFACE'}) ==")
print(f"  total: {total_delta}  ({total_delta/$DUR:.0f}/s)")

# Throughput from client.log
import os
log = open("$OUT/client.log").read() if os.path.exists("$OUT/client.log") else ""
print("== iperf3 client summary ==")
for line in log.splitlines()[-15:]:
    if 'sender' in line or 'receiver' in line or 'Mbits' in line or 'Gbits' in line:
        print("  " + line.strip())
PYEOF

echo "[cycle done] $OUT"
cat "$OUT/summary.txt"
