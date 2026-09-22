#!/bin/bash
# ladder_udp_mean.sh — UDP 제공률 사다리, **평균 기준** 최적점 탐색
#
# 배경: cv 가 5~14% 인 계라 N=1 비교는 무효다 (오늘 ring +18% 주장이 N=1 뽑기로 판명).
#   따라서 모든 점을 N 회 반복하고 평균/표준편차로만 판단한다.
#   또한 46G 가 UDP 에 최적이라는 근거가 없으므로 사다리로 평균 최적점을 찾는다.
#   TCP 는 스스로 동작점을 고르므로 참조선으로 한 번만 잰다.
#
#   usage: ladder_udp_mean.sh <ring_label> [N] [dur] [buf_bytes]
set -u
RINGLBL="${1:?ring label}"; N="${2:-5}"; DUR="${3:-15}"; BUF="${4:-1048576}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/ladder_ring${RINGLBL}_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
RING=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
ssh sslab4 "uname -r" | tee "$LOG/verify.log"
echo "ring=$RING buf=$BUF N=$N dur=${DUR}s" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

run_udp() {  # run_udp <rate> <i>
  local b="$1"; local i="$2"
  local d="$LOG/udp_b${b}_$i"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=$BUF net.core.rmem_max=$BUF >/dev/null"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true
  local rx tx busy
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  tx=$(grep sender   "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  # sender flake 는 제외 (tx < 0.97*offered)
  if [ -z "$tx" ] || awk -v t="${tx:-0}" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then
    echo "  (FLAKE tx=$tx skipped)" | tee -a "$LOG/summary.txt"; return
  fi
  echo "udp $b ${rx:-NA} ${busy:-NA}" >> "$LOG/raw.txt"
  printf "  b=%-3s #%s rx=%-6s busy=%-4s\n" "$b" "$i" "${rx:-NA}" "${busy:-NA}%" | tee -a "$LOG/summary.txt"
}

run_tcp() {  # 참조선
  local i="$1"
  local d="$LOG/tcp_$i"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.ipv4.tcp_rmem='4096 $BUF $BUF' net.core.rmem_max=$BUF >/dev/null"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -l 1M -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true
  local rx busy
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  echo "tcp 0 ${rx:-NA} ${busy:-NA}" >> "$LOG/raw.txt"
  printf "  tcp #%s rx=%-6s busy=%-4s\n" "$i" "${rx:-NA}" "${busy:-NA}%" | tee -a "$LOG/summary.txt"
}

echo "=== TCP 참조선 (N=$N) ===" | tee -a "$LOG/summary.txt"
for i in $(seq 1 $N); do run_tcp "$i"; done

for b in ${RATES:-40 44 48 52 56}; do
  echo "=== UDP offered ${b}G (N=$N) ===" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do run_udp "$b" "$i"; done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 (평균 기준) ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; v[k]=v[k]" "$3}
  END{ for(k in v){ n=split(v[k],a," "); s=0; for(i=1;i<=n;i++)s+=a[i]; m=s/n;
       ss=0; for(i=1;i<=n;i++){d=a[i]-m; ss+=d*d} sd=(n>1)?sqrt(ss/(n-1)):0
       mn=a[1]; mx=a[1]; for(i=1;i<=n;i++){if(a[i]<mn)mn=a[i]; if(a[i]>mx)mx=a[i]}
       printf "%-10s n=%-2d mean=%6.1f sd=%5.2f cv=%4.1f%% min=%5.1f max=%5.1f\n", k, n, m, sd, 100*sd/m, mn, mx } }' \
  "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"

ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 net.ipv4.tcp_rmem='4096 131072 6291456' >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
