#!/bin/bash
# probe_state_cost.sh — good state vs bad state에서 per-byte 비용 구조 직접 계측
# 측정: recvmsg당 반환 바이트(=GRO merge 실효), skb_condense 호출수, busylock 획득수, enqueue 호출수
set -u
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/state_cost_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0; DUR=20

BPF='kretprobe:udp_recvmsg /retval>0/ { @recv_bytes_hist=hist(retval); @recv_calls=count(); @recv_total=sum(retval); }
kprobe:skb_condense { @skb_condense=count(); }
kprobe:__udp_enqueue_schedule_skb { @enqueue=count(); }
kprobe:udp_queue_rcv_one_skb { @rcv_one=count(); }
interval:s:'"$DUR"' { exit(); }'

run() {  # run <name> <rate>
  local name="$1"
  local b="$2"
  local d="$LOG/$name"
  mkdir -p "$d"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 & local SP=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t 30" > "$d/client.log" 2>&1 & local CP=$!
  sleep 4   # 정상상태 진입 후 계측
  ssh sslab4 "sudo timeout $((DUR+10)) bpftrace -e '$BPF'" > "$d/bpf.txt" 2>&1
  ssh sslab4 "mpstat -P 1 1 3" > "$d/mpstat.log" 2>&1
  wait $CP 2>/dev/null || true
  ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"; wait $SP 2>/dev/null || true
  local rx; rx=$(grep receiver "$d/client.log" | tail -1)
  echo "=== $name (offered ${b}G) ===" | tee -a "$LOG/summary.txt"
  echo "$rx" | tee -a "$LOG/summary.txt"
  grep -E '@recv_calls|@recv_total|@skb_condense|@enqueue|@rcv_one' "$d/bpf.txt" | tee -a "$LOG/summary.txt"
  python3 - "$d/bpf.txt" <<'PY' | tee -a "$LOG/summary.txt"
import re,sys
t=open(sys.argv[1]).read()
g=lambda k:(int(m.group(1)) if (m:=re.search(rf'@{k}:\s*(\d+)',t)) else 0)
c,tot,one,enq,cond=g('recv_calls'),g('recv_total'),g('rcv_one'),g('enqueue'),g('skb_condense')
if c: print(f"  → bytes/recvmsg = {tot/c:,.0f}  ({tot/c/8972:.1f} datagrams/recvmsg)")
if one: print(f"  → condense/rcv_one = {cond/one:.2f}   enqueue/rcv_one = {enq/one:.2f}")
PY
  echo "" | tee -a "$LOG/summary.txt"
}

ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=536870912 net.core.rmem_default=212992 net.ipv4.udp_rx_shed=1 net.ipv4.udp_early_drop=0" > "$LOG/setup.log" 2>&1
for rep in 1 2; do
  run "good_r${rep}_b33" 33
  run "bad_r${rep}_b35"  35
done
ssh sslab4 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
