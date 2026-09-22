#!/bin/bash
# probe_cat_ways.sh — Intel CAT 으로 LLC 를 인위적으로 줄여 절벽이 따라 움직이는지 본다
#
# PMU 측정(probe_cache_counters.sh)으로 "워킹셋이 L3 크기(18MB)를 넘으면 무너진다"
# 까지 확인했다. 그런데 18MB 는 **관측된 임계값**이지, 그것이 L3 때문이라는 것은
# 아직 상관관계다. CAT 으로 L3 를 9MB/4.5MB/3MB 로 줄였을 때 임계값이 같은 비율로
# 따라 내려오면 **인과**가 된다.
#
# 방법: resctrl 그룹에 cpu1 을 넣고 way 마스크를 바꾼다.
#   12 way = fff = 18MB,  6 way = 03f = 9MB,  3 way = 007 = 4.5MB,  2 way = 003 = 3MB
#   ring 은 128 고정(descriptor 2MB) -> 워킹셋 = 2MB + rcvbuf
#
# 예측 (인과라면):
#   18MB -> rcvbuf 16M 에서 절벽 (워킹셋 18MB)
#    9MB -> rcvbuf  ~7M 에서 절벽
#  4.5MB -> rcvbuf ~2.5M 에서 절벽
#    3MB -> rcvbuf   ~1M 에서 절벽
# 반증: way 를 줄여도 절벽이 16M 에 머물면 L3 크기가 원인이 아니다.
#
# 주의: DDIO 쓰기는 별도의 예약 way 를 쓰므로 CAT 마스크의 직접 대상이 아니다.
#   여기서 제한되는 것은 **소비자가 copyout 할 때의 읽기**다. 그래도 큐를 담아둘
#   실효 용량이 줄므로 임계값은 움직여야 한다.
#
#   usage: probe_cat_ways.sh <mask_hex> <label> [N] [rate]
set -u
MASK="${1:?mask hex e.g. fff/03f/007/003}"; LABEL="${2:?label e.g. 12way}"
N="${3:-3}"; RATE="${4:-44}"; DUR=12
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/cat_${LABEL}_${TS}; mkdir -p "$LOG"
SRV_IP=192.168.11.238; PORT=5301; IF=ens81f0np0

RING=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
[ "$RING" = 128 ] || { echo "FATAL ring=$RING (128 이어야 함)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/verify.log"
echo "mask=$MASK label=$LABEL ring=$RING rate=${RATE}G" | tee -a "$LOG/verify.log"
echo "(L3 마스크는 스크립트 밖에서 설정/검증한다)" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

for c in 256K:262144 1M:1048576 2M:2097152 4M:4194304 8M:8388608 16M:16777216; do
  cap="${c%%:*}"; bytes="${c##*:}"
  for i in $(seq 1 $N); do
    d="$LOG/${cap}_$i"; mkdir -p "$d"
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes net.core.rmem_max=$bytes net.ipv4.udp_rx_shed=0 >/dev/null"
    ssh sslab4 "taskset -c 1 /home/chanseo/udp_sink $SRV_IP $PORT 2 $DUR" > "$d/sink.log" 2>&1 &
    SP=$!
    sleep 1
    ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PORT 8972 7 $((DUR-2)) $RATE" > "$d/blast.log" 2>&1 || true
    wait $SP 2>/dev/null || true
    got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
    [ -z "${got:-}" ] && { echo "  (sink 실패)" | tee -a "$LOG/summary.txt"; continue; }
    printf "  %-6s %-5s #%-2s got=%s\n" "$LABEL" "$cap" "$i" "$got" | tee -a "$LOG/summary.txt"
    echo "$LABEL $cap $got" >> "$LOG/raw.txt"
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{g[$2]+=$3; n[$2]++} END{for(k in n) printf "%-5s  got=%6.2f  (n=%d)\n", k, g[k]/n[k], n[k]}' \
  "$LOG/raw.txt" | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
