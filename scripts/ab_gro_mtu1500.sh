#!/bin/bash
# ab_gro_mtu1500.sh — Phase B 재측정 (버그 수정판)
#
# 버그: UDP_GRO setsockopt는 receiver(sslab4)가 건다. 이전 스크립트는
#       IPERF3_UDP_GRO 를 sender(sslab3)에 넘겨서 두 arm 모두 GRO ON 이었다.
#       -> env 를 server 쪽에 건다.
# 주의: GRO off 면 iperf3 의 datagram 집계가 깨져(GSO 세그먼트 대부분이
#       iperf3 헤더 없음) loss/rx 수치가 무의미하다. **busy 만 유효 지표.**
set -u
DUR="${1:-15}"; REPS="${2:-3}"; RATE="${3:-25}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/gro1500_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 1500 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
ssh sslab4 "sudo sysctl -w net.core.rmem_default=1572864 net.ipv4.udp_rx_shed=0 >/dev/null; uname -r" | tee "$LOG/verify.log"

one() {  # one <tag> <gro 0|1> <rep>
  local tag="$1"; local gro="$2"; local rep="$3"
  local d="$LOG/${tag}_r${rep}"; mkdir -p "$d"
  # *** env 를 server(sslab4)에 건다 ***
  ssh sslab4 "IPERF3_UDP_GRO=$gro taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${RATE}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true

  local busy tx srvmode
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.1f",100-id/m}' "$d/mpstat.log")
  tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  srvmode=$(grep -oE 'UDP_GRO mode|plain recvmsg|GRO' "$d/server.log" | head -1)
  printf "%-10s r%s | rxbusy=%-6s tx=%-6s  [server: %s]\n" \
    "$tag" "$rep" "${busy:-NA}%" "${tx:-NA}" "${srvmode:-?}" | tee -a "$LOG/summary.txt"
}

echo "=== app GRO on/off @ MTU1500, offered ${RATE}G (busy 만 유효) ===" | tee -a "$LOG/summary.txt"
for rep in $(seq 1 $REPS); do
  one "gro_on"  1 "$rep"
  one "gro_off" 0 "$rep"
done
awk '/gro_on/{split($4,a,"=");split(a[2],b,"%");s1+=b[1];n1++} /gro_off/{split($4,a,"=");split(a[2],b,"%");s2+=b[1];n2++}
     END{printf "\nMEAN busy: gro_on=%.1f%%  gro_off=%.1f%%  delta=%+.1f%%p\n",s1/n1,s2/n2,s2/n2-s1/n1}' \
     "$LOG/summary.txt" | tee -a "$LOG/summary.txt"
ssh sslab4 "pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
