#!/bin/bash
# Usage: dim_trace.sh <duration_s> [iface=ens81f0np0] [host=sslab4] [interval_ms=500]
# rx-usecs와 rx-frames를 polling해서 DIM profile_ix를 역추적 + bpftrace로 net_dim 호출 빈도
set -e
DUR="${1:?usage: dim_trace.sh dur_s}"
IFACE="${2:-ens81f0np0}"
HOST="${3:-sslab4}"
INT_MS="${4:-500}"
TS=$(date +%Y%m%d_%H%M%S)
OUT=~/lab/reports/dim_trace_${TS}
mkdir -p "$OUT"

echo "[dim_trace] $HOST/$IFACE for ${DUR}s, polling ${INT_MS}ms → $OUT"

# bpftrace: net_dim, net_dim_decision 호출 카운트 (총량만)
BPF='
kprobe:net_dim       { @net_dim_calls = count(); }
kprobe:net_dim_step  { @step_calls = count(); }
kprobe:net_dim_stats_compare { @compare_calls = count(); }
kprobe:mlx5e_handle_rx_dim { @handle_rx_dim = count(); }
kprobe:mlx5e_napi_poll { @napi_poll_entries = count(); }
'
ssh $HOST "sudo timeout $((DUR+2)) bpftrace -e '$BPF'" > "$OUT/bpf.txt" 2>&1 &
BPID=$!

# ethtool -c 폴링: rx-usecs와 rx-frames 시계열 (0.5s 고정)
ssh $HOST "for i in \$(seq 1 $((DUR*2))); do
    t=\$(date +%s.%N)
    eval \$(ethtool -c $IFACE 2>/dev/null | awk -F: '
        /^Adaptive RX/ {gsub(/ /,\"\",\$2); printf \"A=%s; \", \$2}
        /^rx-usecs:/   {gsub(/ /,\"\",\$2); printf \"U=%s; \", \$2}
        /^rx-frames:/  {gsub(/ /,\"\",\$2); printf \"F=%s; \", \$2}')
    echo \"\$t \$A \$U \$F\"
    sleep 0.5
done" > "$OUT/ethtool_ts.txt" 2>&1 &
EPID=$!

# nstat 시계열 (sec 1마다)
ssh $HOST "for i in \$(seq 1 $DUR); do
    t=\$(date +%s.%N)
    nstat 2>/dev/null | grep -E 'UdpRcvbufErrors|UdpInDatagrams|UdpInErrors' | awk -v t=\$t '{print t, \$0}'
    sleep 1
done" > "$OUT/nstat_ts.txt" 2>&1 &
NPID=$!

# IRQ 시계열
ssh $HOST "for i in \$(seq 1 $DUR); do
    t=\$(date +%s.%N)
    total=\$(grep mlx5_comp /proc/interrupts | awk '{s=0; for(i=2;i<=NF-3;i++) s+=\$i} END {print s}')
    echo \"\$t \$total\"
    sleep 1
done" > "$OUT/irq_ts.txt" 2>&1 &
IPID=$!

# Wait for sampling to finish
sleep $DUR
sleep 2

ssh $HOST "pkill -INT bpftrace 2>/dev/null; true"
wait $BPID $EPID $NPID $IPID 2>/dev/null || true
echo "[dim_trace done] $OUT"
echo "---bpf---"
tail -10 "$OUT/bpf.txt"
echo "---ethtool 처음+끝 5 sample---"
head -5 "$OUT/ethtool_ts.txt"
echo "..."
tail -5 "$OUT/ethtool_ts.txt"
