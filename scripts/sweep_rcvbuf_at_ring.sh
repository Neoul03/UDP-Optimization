#!/bin/bash
# sweep_rcvbuf_at_ring.sh — 주어진 ring 설정에서 rcvbuf 스윕만 수행한다.
#   ring 변경(ethtool -G)과 그에 따른 combined/IRQ 재적용은 **스크립트 밖에서**
#   직접 수행한다 (복합 sudo 블록이 permission classifier 에 걸리므로).
#
#   usage: sweep_rcvbuf_at_ring.sh <ring_label> [dur] [reps]
#
# 동기 (Sepia OSDI'26 §2): ConnectX MPWQE = 64 pages.
#   ring=1024 + MTU9000 -> 코어당 16MB descriptor page.
#   sslab4 소켓당 L3 = 18MB, 기본 할당자의 유효 LLC 는 ~46% (Sepia Fig.9) -> ~8MB.
#   추정: descriptor page ~= ring/1024 * 16MB
set -u
RINGLBL="${1:?ring label required}"; DUR="${2:-15}"; REPS="${3:-1}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/rcvbuf_ring${RINGLBL}_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

# ---- 전제 assert (리부팅/ring변경으로 조용히 깨지는 것들) ----
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL sslab4 combined=$CH (expected 1)"; exit 1; }
AFF=$(ssh sslab4 "cat /proc/irq/\$(ls /sys/class/net/$IF/device/msi_irqs/ | head -1)/smp_affinity")
[ "$AFF" = 000002 ] || { echo "FATAL irq affinity=$AFF (expected 000002)"; exit 1; }
RING=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
ssh sslab4 "uname -r" | tee "$LOG/verify.log"
echo "ring=$RING combined=$CH irq_aff=$AFF" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

one() {  # one <capname> <bytes> <rate> <rep>
  local cap="$1"; local bytes="$2"; local b="$3"; local rep="$4"
  local d="$LOG/${cap}_b${b}_${rep}"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes >/dev/null"
  local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true

  local rx tx loss busy
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  tx=$(grep sender   "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  printf "ring=%-5s %-5s b=%-3s r%s | rx=%-6s loss=%-7s busy=%-4s tx=%-6s\n" \
    "$RING" "$cap" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "${tx:-NA}" | tee -a "$LOG/summary.txt"
  echo "$RING $cap $b $rep ${rx:-NA} ${loss:-NA} ${busy:-NA}" >> "$LOG/raw.txt"
}

CAPS="256K:262144 512K:524288 1M:1048576 2M:2097152 4M:4194304 8M:8388608"
for rep in $(seq 1 $REPS); do
  for b in 0 46; do
    for c in $CAPS; do one "${c%%:*}" "${c##*:}" "$b" "$rep"; done
    echo "" | tee -a "$LOG/summary.txt"
  done
done

ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
