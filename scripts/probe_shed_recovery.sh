#!/bin/bash
# probe_shed_recovery.sh — shed 윈도의 "회복 지연" 비용을 잰다
#
# 정상상태 스윕이 못 보는 것: shed 는 드롭이 날 때마다 재무장되므로 과부하가
#   지속되는 동안에는 윈도 길이와 거의 무관하게 계속 켜져 있다. 윈도가 실제로
#   손해를 끼치는 순간은 **부하가 끝났을 때** — 이미 소비자가 따라잡았는데도
#   최대 <윈도> 만큼 더 버린다.
#
# 방법: 과부하(72G)를 잠깐 주고 끊은 뒤, 곧바로 천장 아래(40G)로 전환한다.
#   40G 는 단독으로는 무손실이어야 한다(측정됨: 0.04%). 전환 직후의 손실이
#   순수하게 "남은 윈도 때문에 버린 양"이다.
#
#   phase1: 72G x 3s   (윈도 무장)
#   phase2: 40G x 5s   (여기서의 손실을 측정)
#
# 판정: 윈도가 길수록 phase2 손실이 커지면 -> 윈도에 실질 비용이 있고,
#       부하에 맞춰 줄여야 할 이유가 생긴다(컨트롤러 근거).
#       윈도와 무관하면 -> 재무장 구조가 알아서 처리하므로 고정으로 충분.
#
#   usage: probe_shed_recovery.sh [N]
set -u
N="${1:-5}"; BUF=1048576
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/shedrecov_${TS}; mkdir -p "$LOG"
SRV_IP=192.168.11.238; PORT=5301; IF=ens81f0np0

RING=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
ssh sslab4 "uname -r" | tee "$LOG/verify.log"
echo "ring=$RING buf=$BUF" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

one() {  # one <win_us> <i>
  local w="$1"; local i="$2"
  local d="$LOG/w${w}_$i"; mkdir -p "$d"
  if [ "$w" = 0 ]; then
    ssh sslab4 "sudo sysctl -w net.ipv4.udp_rx_shed=0 net.core.rmem_default=$BUF net.core.rmem_max=$BUF >/dev/null"
  else
    ssh sslab4 "sudo sysctl -w net.ipv4.udp_rx_shed=1 net.ipv4.udp_rx_shed_us=$w net.core.rmem_default=$BUF net.core.rmem_max=$BUF >/dev/null"
  fi
  # sink 은 9초 동안 켜두고, sender 가 72G 3s -> 40G 5s 로 전환
  ssh sslab4 "taskset -c 1 /home/chanseo/udp_sink $SRV_IP $PORT 2 10" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PORT 8972 7 3 72" > "$d/p1.log" 2>&1 || true
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PORT 8972 7 5 40" > "$d/p2.log" 2>&1 || true
  wait $SP 2>/dev/null || true

  # phase 별 offered 를 sender 로그에서, 총 수신을 sink 에서 얻어
  # phase2 손실 = (p1+p2 offered) - got - (p1 에서 예상되는 손실)
  # 단순화: p1 단독 손실을 따로 재지 않고, 총 전달량만 비교한다.
  # 윈도가 길수록 총 전달량이 줄면 회복 지연 비용이 있는 것이다.
  local o1 o2 got
  o1=$(grep -oE 'offered=[0-9.]+' "$d/p1.log" | cut -d= -f2)
  o2=$(grep -oE 'offered=[0-9.]+' "$d/p2.log" | cut -d= -f2)
  got=$(grep -oE 'bytes=[0-9]+' "$d/sink.log" | head -1 | cut -d= -f2)
  [ -z "${got:-}" ] && { echo "  (sink 실패)" | tee -a "$LOG/summary.txt"; return; }
  # 총 제공 바이트 = o1*3s + o2*5s  (Gbit -> byte)
  local offb
  offb=$(awk -v a="${o1:-0}" -v b="${o2:-0}" 'BEGIN{printf "%.0f", (a*3+b*5)*1e9/8}')
  local loss
  loss=$(awk -v o="$offb" -v g="$got" 'BEGIN{ if(o>0) printf "%.2f", (o-g)/o*100; else print "NA"}')
  printf "  win=%-6s #%-2s  offered(72G x3s + 40G x5s)  got=%.2f GB  loss=%s%%\n" \
    "${w}us" "$i" "$(awk -v g="$got" 'BEGIN{printf "%.2f", g/1e9}')" "$loss" | tee -a "$LOG/summary.txt"
  echo "$w $loss $got" >> "$LOG/raw.txt"
}

for w in 0 50 200 800 1600; do
  echo "=== window ${w}us ===" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do one "$w" "$i"; done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=== 요약: 윈도가 길수록 손실이 커지면 회복 지연 비용이 실재 ===" | tee -a "$LOG/summary.txt"
awk '{l[$1]+=$2; n[$1]++} END{for(k in n) printf "win=%-6s  총손실 %5.2f%%  (n=%d)\n", (k==0?"off":k"us"), l[k]/n[k], n[k]}' \
  "$LOG/raw.txt" | sort -n | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rx_shed=0 net.ipv4.udp_rx_shed_us=200 net.core.rmem_default=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
