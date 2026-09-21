#!/bin/bash
# 실험 + receiver-side(sslab4) bpftrace + nstat 시계열 동시 수집
# Usage: run_with_monitoring.sh <name> <scmd> <ccmd> <duration> [bpf_script_for_receiver]
NAME="$1"; SCMD="$2"; CCMD="$3"; DUR="${4:-30}"; BPF="${5:-}"
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/${NAME}_${TS}
mkdir -p $LOG

{
  echo "Experiment: $NAME"
  echo "Server (sslab4, receiver): $SCMD"
  echo "Client (sslab3, sender):   $CCMD"
  echo "Duration: ${DUR}s"
  echo "BPF (on sslab4): $BPF"
} | tee $LOG/meta.txt

# Receiver-side bpftrace (sslab4) — DIM/UDP 분석은 receiver가 main target
if [ -n "$BPF" ]; then
  ssh sslab4 "sudo timeout $((DUR+5)) bpftrace -e '$BPF'" > $LOG/bpf_sslab4.log 2>&1 &
  BPF_PID=$!
fi

# nstat 시계열 (receiver side, sslab4)
ssh sslab4 "for i in \$(seq 1 $DUR); do echo \"--- t=\$i ---\"; nstat -az 2>/dev/null | grep -iE 'udp|drop'; sleep 1; done" > $LOG/nstat_sslab4_ts.log 2>&1 &
NSTAT_PID=$!

# Server on sslab4
ssh sslab4 "$SCMD" > $LOG/server.log 2>&1 &
SPID=$!
sleep 2

# Client on sslab3
ssh sslab3 "$CCMD" > $LOG/client.log 2>&1 || true

# Cleanup
ssh sslab4 "pkill -f iperf3 || true"
ssh sslab3 "pkill -f iperf3 || true"
wait $NSTAT_PID 2>/dev/null || true
[ -n "$BPF" ] && wait $BPF_PID 2>/dev/null || true

echo "Done. Log: $LOG"
