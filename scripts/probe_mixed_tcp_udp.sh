#!/bin/bash
# probe_mixed_tcp_udp.sh — TCP 가 UDP 예산을 정말 "캐시로" 침식하는가 (진단 전용)
#
# 예산은 UDP 가 나눠준 용량만 센다. TCP 도 같은 L3 를 쓰므로 원리상 UDP 예산이
# 9MB 여도 TCP 가 6MB 를 쓰면 합이 절벽을 넘는다. 고치기 전에 침식이 측정되는지
# 부터 본다.
#
# 다만 **한쪽에만 제약을 걸면 안 된다**(CLAUDE.md 규칙 6). tcp_rmem 을 줄이면
# TCP 가 느려져 CPU 도 덜 쓰므로, "UDP 가 회복됐다"가 캐시 때문인지 CPU 때문인지
# 갈리지 않는다. 그래서 반대 방향으로도 제약을 건다:
#
#   A_udp_only      UDP 단독                          — 기준
#   B_mixed         UDP autotune + TCP 기본            — 침식이 있다면 여기
#   C_tcp_capped    TCP 버퍼만 256K 로 묶음            — TCP 쪽을 줄임
#   D_udp_capped    UDP autotune 끄고 1M 고정, TCP 기본 — UDP 쪽만 줄임
#
# 판정:
#   D 가 B 보다 좋으면 → 손해는 **UDP 자신의 과성장**이다. 예산이 TCP 를 못 봐서
#      UDP 가 8M 까지 자랐고 합이 절벽을 넘었다. TCP 계상이 정확히 이것을 막는다.
#   D 가 B 와 같으면  → 손해는 CPU 경쟁이다. 예산에 TCP 를 넣어도 소용없다.
#
# 합계 처리량(UDP+TCP)을 반드시 같이 본다. 한쪽이 준 만큼 다른 쪽이 가져간
# 것뿐이면 그것은 병리가 아니라 분배다.
set -u
N="${1:-3}"; DUR=12
SRV_IP=192.168.11.238; PU=5301; PT=5350
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/mixed_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

run() {  # run <label> <with_tcp 0|1> <i>
  local lbl="$1" wtcp="$2" i="$3"
  local d="$LOG/${lbl}_$i"; mkdir -p "$d"
  local TP=""
  if [ "$wtcp" = 1 ]; then
    ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $PT -1" > "$d/tsrv.log" 2>&1 &
    TP=$!
    sleep 2
    ssh sslab3 "taskset -c 3 $IPERF -c $SRV_IP -p $PT -l 1M -t $((DUR+4))" > "$d/tcli.log" 2>&1 &
    sleep 2
  fi
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $PU 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PU 8972 7 $((DUR-2)) 40" > "$d/tx.log" 2>&1
  local rbu; rbu=$(ssh sslab4 "ss -uam state unconnected sport = :$PU 2>/dev/null | grep -oE 'rb[0-9]+' | head -1")
  wait $SP 2>/dev/null || true
  # TCP 수치는 **서버 로그**에서 읽는다. 서버를 죽이고 나면 클라이언트의
  # receiver 줄은 0.00 으로 찍힌다 (실제로 그렇게 세 번 0 을 읽었다).
  sleep 3
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  [ -n "$TP" ] && { wait $TP 2>/dev/null || true; }
  local u t off ok
  u=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  t=$(grep receiver "$d/tsrv.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ Gbits/sec' | head -1 | awk '{print $1}')
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  ok=$(awk -v o="${off:-0}" 'BEGIN{print (o >= 0.97*40) ? 1 : 0}')
  local tot; tot=$(awk -v a="${u:-0}" -v b="${t:-0}" 'BEGIN{printf "%.2f", a+b}')
  printf "  %-14s #%-2s  udp=%-7s tcp=%-7s 합계=%-7s  udp_rb=%s%s\n" \
     "$lbl" "$i" "${u:-NA}" "${t:--}" "$tot" "${rbu:-NA}" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=${off}, 제외")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$lbl ${u:-0} ${t:-0}" >> "$LOG/raw.txt"
}

AT="net.core.rmem_default=1048576 net.core.rmem_max=536870912 net.ipv4.udp_rmem_autotune=1 \
    net.ipv4.udp_rmem_autotune_max=67108864 net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=0"
TCPD="net.ipv4.tcp_rmem='4096 131072 6291456'"
for i in $(seq 1 $N); do
  ssh sslab4 "sudo sysctl -w $AT $TCPD >/dev/null"
  run "A_udp_only"   0 "$i"
  run "B_mixed"      1 "$i"
  ssh sslab4 "sudo sysctl -w $AT net.ipv4.tcp_rmem='4096 65536 262144' >/dev/null"
  run "C_tcp_capped" 1 "$i"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
      net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 $TCPD >/dev/null"
  run "D_udp_capped" 1 "$i"
done

echo "" | tee -a "$LOG/summary.txt"
awk '{u[$1]+=$2; t[$1]+=$3; n[$1]++}
 END{for(k in n) printf "%-14s udp=%6.2f  tcp=%6.2f  합계=%6.2f  (n=%d)\n",
     k, u[k]/n[k], t[k]/n[k], (u[k]+t[k])/n[k], n[k]}' "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.core.rmem_default=212992 net.core.rmem_max=212992 net.ipv4.tcp_rmem='4096 131072 6291456' >/dev/null; pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
