#!/bin/bash
# sweep_rcvbuf_counters.sh — rcvbuf 스윕 + **드롭 위치 분해**
#
# 왜 필요한가: ring 을 줄이면 캐시 워킹셋이 줄어 좋아질 수도 있지만,
#   동시에 ring 자체가 넘쳐서 나빠질 수도 있다. 처리량만 보면 구분이 불가능하다.
#   두 드롭은 발생 지점이 다르므로 카운터로 분리한다:
#
#   rx_out_of_buffer   (ethtool -S)  : NIC 가 descriptor 를 못 얻어 버림  -> **ring 부족**
#   UdpRcvbufErrors    (nstat)       : 소켓 수신 큐가 가득 차 버림        -> **소비자 지연**
#   rx_discards_phy    (ethtool -S)  : PHY 레벨 폐기
#
# 판정: ring 을 줄였을 때 UdpRcvbufErrors 가 줄면 캐시 효과(소비가 빨라짐),
#       rx_out_of_buffer 가 늘면 ring 부족. 둘을 같이 봐야 한다.
#
#   usage: sweep_rcvbuf_counters.sh <ring_label> [dur] [reps] [rate]
set -u
RINGLBL="${1:?ring label}"; DUR="${2:-15}"; REPS="${3:-1}"; RATE="${4:-46}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/cnt_ring${RINGLBL}_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
RING=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
ssh sslab4 "uname -r" | tee "$LOG/verify.log"
echo "ring=$RING combined=$CH rate=${RATE}G" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

snap() {  # NIC + UDP 카운터 한 줄로
  ssh sslab4 "ethtool -S $IF 2>/dev/null | awk '/rx_out_of_buffer|rx_discards_phy|rx_buff_alloc_err/{gsub(/:/,\"\",\$1); printf \"%s=%s \", \$1, \$2}';
              nstat -az 2>/dev/null | awk '/UdpRcvbufErrors|UdpInErrors|UdpInDatagrams/{printf \"%s=%s \", \$1, \$2}'; echo"
}
delta() {  # delta <before> <after> <key>
  local b a
  b=$(echo "$1" | tr ' ' '\n' | grep "^$3=" | cut -d= -f2)
  a=$(echo "$2" | tr ' ' '\n' | grep "^$3=" | cut -d= -f2)
  [ -n "$b" ] && [ -n "$a" ] && echo $((a - b)) || echo NA
}

one() {  # one <capname> <bytes> <rep>
  local cap="$1"; local bytes="$2"; local rep="$3"
  local d="$LOG/${cap}_${rep}"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes >/dev/null"
  local B A
  B=$(snap)
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${RATE}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true
  A=$(snap)
  echo "$B" > "$d/before.txt"; echo "$A" > "$d/after.txt"

  local rx loss busy oob rbe disc
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  oob=$(delta "$B" "$A" rx_out_of_buffer)
  disc=$(delta "$B" "$A" rx_discards_phy)
  rbe=$(delta "$B" "$A" UdpRcvbufErrors)
  printf "ring=%-5s %-5s | rx=%-6s loss=%-6s busy=%-4s | ring_drop=%-10s sock_drop=%-10s phy=%-8s\n" \
    "$RING" "$cap" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "$oob" "$rbe" "$disc" | tee -a "$LOG/summary.txt"
  echo "$RING $cap $rep ${rx:-NA} ${loss:-NA} ${busy:-NA} $oob $rbe $disc" >> "$LOG/raw.txt"
}

CAPS="256K:262144 512K:524288 1M:1048576 2M:2097152 4M:4194304 8M:8388608"
for rep in $(seq 1 $REPS); do
  echo "===== ring=$RING rate=${RATE}G rep=$rep  (ring_drop=rx_out_of_buffer, sock_drop=UdpRcvbufErrors) =====" | tee -a "$LOG/summary.txt"
  for c in $CAPS; do one "${c%%:*}" "${c##*:}" "$rep"; done
  echo "" | tee -a "$LOG/summary.txt"
done

ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
