#!/bin/bash
# Usage: run_experiment.sh <name> <server_cmd> <client_cmd> [duration]
# server: sslab4 (receiver), client: sslab3 (sender)
set -e
NAME="$1"; SCMD="$2"; CCMD="$3"; DUR="${4:-30}"
TS=$(date +%Y%m%d_%H%M%S)
LOG=~/lab/logs/${NAME}_${TS}
mkdir -p $LOG

{
  echo "Experiment: $NAME"
  echo "Server (sslab4, receiver): $SCMD"
  echo "Client (sslab3, sender):   $CCMD"
  echo "Duration: ${DUR}s"
  echo "Started: $(date -Iseconds)"
} | tee $LOG/meta.txt

# Server (receiver) on sslab4, background
ssh sslab4 "$SCMD" > $LOG/server.log 2>&1 &
SSH_PID=$!
sleep 2

# Client (sender) on sslab3, foreground
ssh sslab3 "$CCMD" > $LOG/client.log 2>&1 || true

# Cleanup both sides
ssh sslab4 "pkill -f iperf3 || true" 2>/dev/null
ssh sslab3 "pkill -f iperf3 || true" 2>/dev/null
wait $SSH_PID 2>/dev/null || true

# Post-run stats — receiver side가 핵심
ssh sslab4 "nstat -az 2>/dev/null | grep -iE 'udp|tcp'" > $LOG/sslab4_receiver_nstat.log
ssh sslab3 "nstat -az 2>/dev/null | grep -iE 'udp|tcp'" > $LOG/sslab3_sender_nstat.log

echo "Done. Log: $LOG"
