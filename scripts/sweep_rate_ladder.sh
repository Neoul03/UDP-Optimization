#!/bin/bash
# sweep_rate_ladder.sh — 제공률 사다리. x = sender 가 요청한 속도, y = 배달된 처리량.
#
# 왜 이게 필요한가: 지금까지의 격자 캠페인은 UDP 에 sender 최대치의 90%(MTU 9000
# 에서 88G)를 밀어넣었는데 수신 천장은 ~55G 다. 즉 **UDP 만 1.6배 과부하**에
# 놓고 TCP 는 혼잡제어로 자기 평형에 앉아 있었다. TCP 값이 제공 56G 캠페인과
# 88G 캠페인에서 거의 같았던 것이 그 증거다 (55.72 vs 56.50).
#   -> "UDP vs TCP" 를 그 데이터로 주장하면 안 된다. 규칙 6 의 변종.
#
# 그래서 세 arm 모두에 **같은 x 축**을 준다: 앱이 요청한 송신 속도.
#   UDP  udp_blast 의 byte-budget 스핀 페이싱
#   TCP  iperf3 -b (앱 레벨 페이싱)
# TCP 는 -b 위에 자기 혼잡제어가 또 있으므로 min(요청, 자기평형) 을 낸다.
# 그게 정확히 이 그래프가 보여줘야 하는 것이다.
#
# arm 세 개 (사용자 지정):
#   udp_sockopt  앱이 SO_RCVBUF 64MB 요청 -> rmem_max 기본값에 막혀 416KB.
#                고속 UDP 앱의 현실적 기준선이다.
#   udp_ours     autotune=1 cache_pct=50 shed=1   (사다리 내내 고정)
#   tcp          tcp_rmem 은 건드리지 않는다
#
# 한계: UDP 는 udp_blast->udp_sink, TCP 는 iperf3 로 잰다. 도구가 다른 것은
# 어쩔 수 없지만 confound 이므로 기록해 둔다.
set -u
N="${1:-5}"; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301; TP=5351
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/ladder_${TS}; mkdir -p "$LOG"
RATES="5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80"

TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "sudo ethtool -G $IF rx 128 >/dev/null 2>&1"; sleep 4
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1"; sleep 2
GOV=$(ssh sslab4 "cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor")
[ "$GOV" = performance ] || { echo "FATAL governor=$GOV"; exit 1; }
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"; sleep 3
for h in sslab4 sslab3; do
  m=$(ssh $h "ip link show $IF | grep -o 'mtu [0-9]*' | awk '{print \$2}'")
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'; ethtool -c $IF | grep -i adaptive; sysctl -n net.ipv4.tcp_rmem" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

setcfg() {
  case "$1" in
    udp_sockopt)
      ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
          net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    udp_ours)
      ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 67108864' net.core.rmem_max=212992 \
          net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
    tcp) : ;;
  esac
}

one() {  # one <cfg> <rate> <i>
  local cfg="$1"
  local rate="$2"
  local i="$3"
  local d="$LOG/${cfg}_r${rate}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  local got=""
  local tx=""
  if [ "$cfg" = tcp ]; then
    ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $TP -1" > "$d/srv.log" 2>&1 &
    local SV=$!
    sleep 2
    ssh sslab3 "taskset -c 1 $IPERF -c $SRV_IP -p $TP -b ${rate}G -l 1M -t 11" > "$d/cli.log" 2>&1 &
    ssh sslab4 "mpstat -P 1 1 9" > "$d/mp.log" 2>&1
    sleep 3; ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
    wait $SV 2>/dev/null || true
    got=$(grep receiver "$d/srv.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
          | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
    tx=$(grep sender "$d/cli.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
          | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
  else
    local env
    [ "$cfg" = udp_sockopt ] && env="UDP_SINK_RCVBUF=67108864" || env="UDP_SINK_NO_RCVBUF=1"
    ssh sslab4 "$env taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 12" > "$d/sink.log" 2>&1 &
    local SK=$!
    sleep 1
    ssh sslab3 "taskset -c 1 timeout 16 /home/chanseo/udp_blast $SRV_IP $P 8972 7 10 $rate" > "$d/tx.log" 2>&1 &
    ssh sslab4 "mpstat -P 1 1 9" > "$d/mp.log" 2>&1
    wait $SK 2>/dev/null || true
    got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
    tx=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  fi
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  # sender flake 배제. TCP 는 혼잡제어가 스스로 줄이는 게 정상이므로 검사하지 않는다.
  local ok=1
  [ "$cfg" != tcp ] && ok=$(awk -v o="${tx:-0}" -v r="$rate" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  %-12s rate=%-3s #%-2s got=%-7s tx=%-7s busy=%s%s\n" \
     "$cfg" "$rate" "$i" "${got:-NA}" "${tx:-NA}" "${busy:-NA}%" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && [ -n "${got:-}" ] && echo "$rate $cfg $got ${tx:-0} ${busy:-0}" >> "$LOG/raw.txt"
}

for rate in $RATES; do
  echo "===== 요청 ${rate} Gb/s =====" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do
    for c in udp_sockopt udp_ours tcp; do one "$c" "$rate" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 (평균±sd) ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; g[k]+=$3; gg[k]+=$3*$3; t[k]+=$4; b[k]+=$5; n[k]++}
 END{for(k in n){split(k,x," "); mu=g[k]/n[k]; sd=sqrt(gg[k]/n[k]-mu*mu);
   printf "rate %-3s  %-12s  got=%6.2f +-%5.2f  tx=%6.2f  busy=%3.0f%%  (n=%d)\n",
   x[1],x[2],mu,sd,t[k]/n[k],b[k]/n[k],n[k]}}' "$LOG/raw.txt" | sort -k2,2n -k4,4 | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null
    pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
