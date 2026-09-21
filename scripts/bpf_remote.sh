#!/bin/bash
# Usage: bpf_remote.sh <host> <duration> <bpftrace_script>
# Receiver-side trace: host = sslab4
# Sender-side trace:   host = sslab3
HOST="$1"; DUR="$2"; SCRIPT="$3"
TS=$(date +%Y%m%d_%H%M%S)
OUT=~/lab/logs/bpf_${HOST}_${TS}.txt
ssh $HOST "sudo timeout $DUR bpftrace -e '$SCRIPT'" > $OUT 2>&1 || true
echo "bpftrace output: $OUT"
