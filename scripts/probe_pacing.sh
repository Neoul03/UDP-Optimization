#!/bin/bash
# probe_pacing.sh — 도구 차이가 **송신 버스트성** 때문인지 직접 시험한다.
#
# 관측: MTU 9000 / 65G / 기존 UDP(416KB) 에서 두 도구가 갈린다 (교대 5회씩, 5/5 분리)
#   udp_blast → udp_sink   14.70 +- 0.86
#   iperf3    → iperf3     27.24 +- 1.17
# 병합 깊이는 거의 같다 (6.70 vs 6.18) -> GSO 꼬다리 가설은 기각됐다.
#
# 남은 가설: 도착의 **시간 구조**가 다르다.
#   udp_blast  스핀 페이싱 -> 정확히 균일한 간격
#   iperf3     clock_nanosleep -> 늦게 깬 만큼 몰아서 보내고 쉼
# 작은 버퍼는 "poll 사이에 소비자가 비울 틈이 있느냐"에 민감하고, 버스트는 그 틈을
# 만들어 준다는 해석이다.
#
# 2x2 교차(송신 blast + 수신 iperf3)는 불가능하다 - iperf3 는 제어 채널 때문에 양 끝이
# 모두 iperf3 여야 한다. 대신 **양 끝을 iperf3 로 고정하고 --pacing-timer 만 바꾼다**.
# 다른 모든 것이 같으므로 이것이 송신 버스트성의 순수 효과다.
#
#   가설이 맞으면: 타이머가 짧을수록(균일) 기존 UDP 가 udp_blast 쪽 값(~15)으로 내려가고,
#                  길수록(버스트) 오른다. ours 는 둘 다에 둔감하다.
#   가설이 틀리면: 타이머를 바꿔도 평탄하다 -> 원인은 다른 곳(수신 오버헤드 등)이다.
set -u
N="${1:-5}"; RATE="${2:-65}"; IF=ens81f0np0
SRV_IP=192.168.11.238; UP=5302
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/pacing_${TS}; mkdir -p "$LOG"
TIMERS="20 100 250 1000 4000 10000"      # us. 1000 이 iperf3 기본값

TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
for h in sslab4 sslab3; do
  m=$(ssh $h "ip link show $IF | grep -o 'mtu [0-9]*' | awk '{print \$2}'")
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'; ethtool -c $IF | grep -i adaptive" | tee "$LOG/summary.txt"
echo "양 끝 iperf3 고정, --pacing-timer 만 변경. MTU 9000, 요청 ${RATE}G, 단일 flow" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

setcfg() {
  case "$1" in
    udp)  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
              net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    ours) ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 67108864' net.core.rmem_max=212992 \
              net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
  esac
}

one() {  # one <cfg> <timer_us> <i>
  local cfg="$1"
  local pt="$2"
  local i="$3"
  local d="$LOG/${cfg}_t${pt}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  local w=""
  [ "$cfg" = udp ] && w="-w 208K"
  ssh sslab4 "IPERF3_UDP_GRO=1 taskset -c 1 $IPERF -s -B $SRV_IP -p $UP -1" > "$d/srv.log" 2>&1 &
  local SV=$!
  sleep 2
  ssh sslab3 "taskset -c 1 $IPERF -c $SRV_IP -p $UP -u -b ${RATE}G -l 65000 $w --pacing-timer $pt -t 10" \
      > "$d/cli.log" 2>&1 &
  ssh sslab4 "mpstat -P 1 1 8" > "$d/mp.log" 2>&1
  sleep 3; ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SV 2>/dev/null || true

  local got; got=$(grep receiver "$d/srv.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
        | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
  local tx; tx=$(grep sender "$d/cli.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
        | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
  local loss; loss=$(grep -oE '\([0-9.]+%\)' "$d/srv.log" 2>/dev/null | tail -1 | tr -d '()%')
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  local ok; ok=$(awk -v o="${tx:-0}" -v r="$RATE" 'BEGIN{print (o >= 0.95*r) ? 1 : 0}')
  printf "  %-5s timer=%-6s #%-2s got=%-7s tx=%-7s loss=%-7s busy=%s%s\n" \
     "$cfg" "${pt}us" "$i" "${got:-NA}" "${tx:-NA}" "${loss:-NA}%" "${busy:-NA}%" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && [ -n "${got:-}" ] && echo "$pt $cfg $got ${tx:-0} ${busy:-0} ${loss:-0}" >> "$LOG/raw.txt"
}

for pt in $TIMERS; do
  echo "===== --pacing-timer ${pt} us =====" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do
    for c in udp ours; do one "$c" "$pt" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 (평균±sd) ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; g[k]+=$3; gg[k]+=$3*$3; b[k]+=$5; l[k]+=$6; n[k]++}
 END{for(k in n){split(k,x," "); mu=g[k]/n[k]; sd=sqrt(gg[k]/n[k]-mu*mu);
   printf "timer %-6s %-5s  got=%6.2f +-%5.2f  loss=%5.1f%%  busy=%3.0f%%  (n=%d)\n",
   x[1]"us",x[2],mu,sd,l[k]/n[k],b[k]/n[k],n[k]}}' "$LOG/raw.txt" | sort -k2,2n -k3,3 | tee -a "$LOG/summary.txt"
echo "" | tee -a "$LOG/summary.txt"
echo "참고: 같은 조건 udp_blast(스핀, 완전 균일) = 14.70 +- 0.86 / iperf3 기본(1000us) = 27.24 +- 1.17" | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null
    pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
