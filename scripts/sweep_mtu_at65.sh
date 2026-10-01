#!/bin/bash
# sweep_mtu_at65.sh — 제공률 65 Gb/s 고정, MTU 1500..9000 을 x 축에.
#
# 사다리(sweep_rate_ladder.sh)와 짝이다. 거기서는 MTU 9000 을 고정하고 속도를
# 움직였고, 여기서는 속도를 고정하고 MTU 를 움직인다. 65 G 를 고른 이유:
# 사다리에서 세 arm 이 가장 크게 갈리는 지점이다 (우리 60.69 / TCP 54.72 / 기존 15.47).
#
# arm 네 개 (주 그래프는 udp / ours / tcp 세 개, ours_lock 은 진단용).
#   udp        기존 커널 (autotune/cap/shed off). 앱이 SO_RCVBUF 64MB 를 요청해도
#              rmem_max 기본값에 막혀 실제 416KB 다. 오늘의 현실.
#   ours       우리 커널. 앱은 SO_RCVBUF 를 **부르지 않는다** -> autotune 이 동작한다.
#              사다리(sweep_rate_ladder.sh)의 ours 와 같은 정의라 교차검증이 된다.
#   tcp        tcp_rmem 은 건드리지 않는다. iperf3 -b 로 같은 65G 를 요청한다.
#   ours_lock  진단용. 우리 커널인데 앱이 SO_RCVBUF 를 부른 경우.
#              SOCK_RCVBUF_LOCK 이 서면 udp_rcvbuf_autotune() 이 스스로 비켜서므로
#              sizing 이 죽고 shed 만 남는다. ours 와의 차이가 그 비용이다.
#              (UDP_GRO 는 네 arm 모두 켜져 있다 - udp_sink mode 2)
#
# ★ sender 가 병목이 되지 않게 MTU 마다 segs 를 조정한다.
#   MTU 1500 에서 segs=7 이면 sendmsg 당 10KB 라 시스템콜에 묶여 44.4G 가 한계다
#   (실측). 65G 를 요청해도 sender 가 못 내면 재는 것은 수신측이 아니라 sender 다.
#   segs = 63000 / payload 로 sendmsg 당 ~63KB 를 맞춘다 -> 시스템콜 부하가 MTU 축에서
#   일정해진다. MTU 9000 에서는 segs=7 이 되어 사다리 실험과 정확히 같다.
#   UDP_MAX_SEGMENTS 는 128 이고 최대 42 를 쓰므로 여유가 있다.
set -u
N="${1:-5}"; RATE="${2:-65}"; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301; TP=5351
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/mtu65_${TS}; mkdir -p "$LOG"
MTUS="1500 3000 4500 6000 7500 9000"

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
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'; ethtool -c $IF | grep -i adaptive" | tee "$LOG/summary.txt"
echo "요청 ${RATE} Gb/s 고정, 단일 flow" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

setmtu() {
  ssh sslab4 "sudo ip link set $IF mtu $1"; ssh sslab3 "sudo ip link set $IF mtu $1"; sleep 3
  local a
  local b
  a=$(ssh sslab4 "ip link show $IF | grep -o 'mtu [0-9]*' | awk '{print \$2}'")
  b=$(ssh sslab3 "ip link show $IF | grep -o 'mtu [0-9]*' | awk '{print \$2}'")
  [ "$a" = "$1" ] && [ "$b" = "$1" ] || { echo "FATAL mtu $a/$b"; return 1; }
}
setcfg() {
  case "$1" in
    udp)  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
              net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    ours|ours_lock)
          ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 67108864' net.core.rmem_max=212992 \
              net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
    tcp)  : ;;
  esac
}
payload() { echo $(( $1 - 28 )); }
segs_for() { echo $(( 63000 / $(payload "$1") )); }   # sendmsg 당 ~63KB

# sender 가 이 MTU 에서 요청 속도를 낼 수 있는지 먼저 확인한다.
probe_sender() {  # probe_sender <mtu> <segs>
  local pl; pl=$(payload "$1")
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 8" >/dev/null 2>&1 &
  local SP=$!
  sleep 1
  local out; out=$(ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P $pl $2 6 0" 2>/dev/null)
  wait $SP 2>/dev/null || true
  echo "$out" | grep -oE 'offered=[0-9.]+' | cut -d= -f2
}

one() {  # one <cfg> <mtu> <segs> <i>
  local cfg="$1"
  local mtu="$2"
  local sg="$3"
  local i="$4"
  local d="$LOG/${cfg}_m${mtu}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  local got=""
  local tx=""
  if [ "$cfg" = tcp ]; then
    ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $TP -1" > "$d/srv.log" 2>&1 &
    local SV=$!
    sleep 2
    ssh sslab3 "taskset -c 1 $IPERF -c $SRV_IP -p $TP -b ${RATE}G -l 1M -t 11" > "$d/cli.log" 2>&1 &
    ssh sslab4 "mpstat -P 1 1 9" > "$d/mp.log" 2>&1
    sleep 3; ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
    wait $SV 2>/dev/null || true
    got=$(grep receiver "$d/srv.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
          | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
    tx=$(grep sender "$d/cli.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
          | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
  else
    # ours 만 SO_RCVBUF 를 부르지 않는다 (autotune 이 동작하도록).
    # 나머지 UDP arm 은 부른다 - 기존 커널에서는 rmem_max 에 막혀 416KB 가 된다.
    local env
    [ "$cfg" = ours ] && env="UDP_SINK_NO_RCVBUF=1" || env="UDP_SINK_RCVBUF=67108864"
    ssh sslab4 "$env taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 12" > "$d/sink.log" 2>&1 &
    local SK=$!
    sleep 1
    local pl; pl=$(payload "$mtu")
    ssh sslab3 "taskset -c 1 timeout 16 /home/chanseo/udp_blast $SRV_IP $P $pl $sg 10 $RATE" > "$d/tx.log" 2>&1 &
    ssh sslab4 "mpstat -P 1 1 9" > "$d/mp.log" 2>&1
    wait $SK 2>/dev/null || true
    got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
    tx=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  fi
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  local ok=1
  [ "$cfg" != tcp ] && ok=$(awk -v o="${tx:-0}" -v r="$RATE" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  mtu=%-5s %-9s #%-2s got=%-7s tx=%-7s busy=%s%s\n" \
     "$mtu" "$cfg" "$i" "${got:-NA}" "${tx:-NA}" "${busy:-NA}%" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && [ -n "${got:-}" ] && echo "$mtu $cfg $got ${tx:-0} ${busy:-0}" >> "$LOG/raw.txt"
}

for mtu in $MTUS; do
  setmtu "$mtu" || continue
  SG=$(segs_for "$mtu")
  SMAX=$(probe_sender "$mtu" "$SG")
  echo "===== MTU $mtu  (segs=$SG, sendmsg당 $(( SG * $(payload $mtu) ))B, sender 최대 ${SMAX:-?}) =====" | tee -a "$LOG/summary.txt"
  awk -v s="${SMAX:-0}" -v r="$RATE" 'BEGIN{ if (s < r) print "  ⚠ sender 가 요청 속도를 못 낸다. 이 MTU 는 sender-bound." }' | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do
    for c in udp ours tcp ours_lock; do one "$c" "$mtu" "$SG" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 (평균±sd) ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; g[k]+=$3; gg[k]+=$3*$3; t[k]+=$4; b[k]+=$5; n[k]++}
 END{for(k in n){split(k,x," "); mu=g[k]/n[k]; sd=sqrt(gg[k]/n[k]-mu*mu);
   printf "MTU %-5s  %-9s  got=%6.2f +-%5.2f  tx=%6.2f  busy=%3.0f%%  (n=%d)\n",
   x[1],x[2],mu,sd,t[k]/n[k],b[k]/n[k],n[k]}}' "$LOG/raw.txt" | sort -k2,2n -k4,4 | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null
    pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
