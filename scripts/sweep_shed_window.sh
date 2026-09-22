#!/bin/bash
# sweep_shed_window.sh — shed 윈도 길이가 부하에 따라 다른 최적값을 갖는가
#
# 배경: 현재 윈도는 200us 고정이었다. 컨트롤러(적응형 윈도)를 만들 이유가 있으려면
#   **부하마다 최적 윈도가 달라야** 한다. 전 구간에서 200us 가 충분하면 고정으로 두는
#   것이 맞고, 컨트롤러는 불필요하다.
#
# 윈도의 역학:
#   짧으면 - 자주 재무장해야 하고, 윈도 사이로 들어온 패킷이 다시 스택 비용을 낸다
#   길면   - 과도하게 버려서, 소비자가 이미 따라잡았는데도 계속 버린다
#   -> 초과분이 클수록 긴 윈도가 유리할 것으로 예상 (c)
#
# 측정: udp_blast(byte-budget pacing) -> udp_sink(UDP_GRO). iperf3 는 쓰지 않는다
#   (sender pacing 양자화가 천장 아래에서 가짜 손실을 만든다).
#
#   usage: sweep_shed_window.sh [N] [dur]
set -u
N="${1:-5}"; DUR="${2:-12}"; BUF=1048576
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/shedwin_${TS}; mkdir -p "$LOG"
SRV_IP=192.168.11.238; PORT=5301; IF=ens81f0np0

for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
RING=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
ssh sslab4 "uname -r; sysctl -n net.ipv4.udp_rx_shed_us" | tee "$LOG/verify.log"
echo "ring=$RING buf=$BUF N=$N" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

one() {  # one <win_us> <rate> <i>   win_us=0 이면 shed off
  local w="$1"; local b="$2"; local i="$3"
  local d="$LOG/w${w}_b${b}_$i"; mkdir -p "$d"
  if [ "$w" = 0 ]; then
    ssh sslab4 "sudo sysctl -w net.ipv4.udp_rx_shed=0 net.core.rmem_default=$BUF net.core.rmem_max=$BUF >/dev/null"
  else
    ssh sslab4 "sudo sysctl -w net.ipv4.udp_rx_shed=1 net.ipv4.udp_rx_shed_us=$w net.core.rmem_default=$BUF net.core.rmem_max=$BUF >/dev/null"
  fi
  ssh sslab4 "taskset -c 1 /home/chanseo/udp_sink $SRV_IP $PORT 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PORT 8972 7 $((DUR-2)) $b" > "$d/blast.log" 2>&1 || true
  wait $SP $MP 2>/dev/null || true
  local got bpc busy
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  bpc=$(grep -oE 'avg_bytes_per_call=[0-9]+' "$d/sink.log" | cut -d= -f2)
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  [ -z "${got:-}" ] && { echo "  (sink 실패)" | tee -a "$LOG/summary.txt"; return; }
  printf "  win=%-5s b=%-3s #%-2s got=%-7s busy=%-4s bytes/call=%s\n" \
    "${w}us" "$b" "$i" "$got" "${busy:-NA}%" "${bpc:-NA}" | tee -a "$LOG/summary.txt"
  echo "$w $b $got ${busy:-0}" >> "$LOG/raw.txt"
}

# 0 = shed off (대조군).  천장(48G) 바로 위부터 한참 위까지.
for b in 52 60 72; do
  echo "===== offered ${b}G =====" | tee -a "$LOG/summary.txt"
  for w in 0 25 50 100 200 400 800 1600; do
    for i in $(seq 1 $N); do one "$w" "$b" "$i"; done
  done
  echo "" | tee -a "$LOG/summary.txt"
done

echo "======= 요약 (부하별 최적 윈도) =======" | tee -a "$LOG/summary.txt"
awk '{k=$2" "$1; g[k]+=$3; b[k]+=$4; n[k]++}
 END{for(k in n){split(k,a," "); printf "%-4sG  win=%-5s  got=%6.2f  busy=%3.0f%%  (n=%d)\n",
     a[1], (a[2]==0?"off":a[2]"us"), g[k]/n[k], b[k]/n[k], n[k]}}' "$LOG/raw.txt" \
  | sort -t= -k1 | sort -n | tee -a "$LOG/summary.txt"

ssh sslab4 "sudo sysctl -w net.ipv4.udp_rx_shed=0 net.ipv4.udp_rx_shed_us=200 net.core.rmem_default=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
