#!/bin/bash
# ab_protocol_isolation.sh — UDP 가 TCP 를 굶기는 것을 막는가 (autotune 켠 상태로)
#
# 이전 측정(TCP 13.8 -> 22.1)은 rmem 1M 고정, autotune 없이 잰 것이다. autotune 이
# 이미 UDP 쪽 붕괴를 막고 있으면 shed 의 한계 기여가 달라진다. 다시 잰다.
#
# 이 주장은 처리량 주장과 **종류가 다르다**: 버퍼 조절로는 원리적으로 안 되는
# 것이다. 버퍼는 큐마다가 아니라 소켓마다 있고, 단일 큐를 공유하는 TCP 는 UDP 의
# 버퍼를 아무리 조절해도 자기 몫을 못 찾는다. shed 는 CQE 의 L4 타입을 보고
# **UDP 만** 골라 버릴 수 있어서 그 구간에 TCP 가 들어갈 자리를 만든다.
#
#   usage: ab_protocol_isolation.sh [reps] [udp_rate]
set -u
N="${1:-5}"; URATE="${2:-64}"; DUR=14; IF=ens81f0np0
SRV_IP=192.168.11.238; PU=5301; PT=5350
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/protiso_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
echo "UDP ${URATE}G + TCP, 단일 큐 공유. shed 는 UDP 만 골라 버린다." | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <arm> <i>
  local arm="$1" i="$2"
  local d="$LOG/${arm}_$i"; mkdir -p "$d"
  case "$arm" in
    auto)      ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
                   net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
                   net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    auto_shed) ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
                   net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
                   net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
    s1M)       ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
                   net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    s1M_shed)  ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
                   net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
  esac
  ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $PT -1" > "$d/tsrv.log" 2>&1 &
  local TP=$!
  sleep 2
  ssh sslab3 "taskset -c 3 $IPERF -c $SRV_IP -p $PT -l 1M -t $DUR" > "$d/tcli.log" 2>&1 &
  sleep 2
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $PU 2 $((DUR-6))" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PU 8972 7 $((DUR-8)) $URATE" > "$d/tx.log" 2>&1
  wait $SP 2>/dev/null || true
  sleep 4
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $TP 2>/dev/null || true
  local u t off
  u=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  # TCP 는 **서버 로그**에서 읽는다. 서버를 죽이면 클라이언트의 receiver 줄이 0 이 된다.
  t=$(grep receiver "$d/tsrv.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ Gbits/sec' | head -1 | awk '{print $1}')
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  local tot; tot=$(awk -v a="${u:-0}" -v b="${t:-0}" 'BEGIN{printf "%.2f", a+b}')
  printf "  %-9s #%-2s  udp=%-7s tcp=%-7s 합계=%-7s (udp tx=%s)\n" \
     "$arm" "$i" "${u:-NA}" "${t:--}" "$tot" "${off:-NA}" | tee -a "$LOG/summary.txt"
  echo "$arm ${u:-0} ${t:-0}" >> "$LOG/raw.txt"
}

for i in $(seq 1 $N); do
  for arm in s1M s1M_shed auto auto_shed; do one "$arm" "$i"; done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{u[$1]+=$2; t[$1]+=$3; n[$1]++}
 END{for(k in n) printf "%-9s udp=%6.2f  tcp=%6.2f  합계=%6.2f  (n=%d)\n", k, u[k]/n[k], t[k]/n[k], (u[k]+t[k])/n[k], n[k]}' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
