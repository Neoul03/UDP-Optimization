#!/bin/bash
# sweep_mtu65_iperf.sh — MTU 축(1500..9000)을 **iperf3 단일 도구**로 다시 잰다.
#
# 왜: sweep_mtu_at65.sh 는 UDP 를 udp_blast/udp_sink 로, TCP 를 iperf3 로 쟀다.
# 도구가 다른 것은 confound 이고, "ours 가 TCP 를 이긴다" 는 주장에 바로 꽂히는
# 질문이다. 여기서는 세 arm 모두 iperf3 로 재서 그 confound 를 없앤다.
# sweep_ladder_iperf.sh 와 짝이다 (거기는 MTU 고정·속도 축, 여기는 속도 고정·MTU 축).
#
# 대신 다른 confound 가 들어온다: iperf3 의 UDP 페이싱은 clock_nanosleep 기반이라
# (iperf_api.c:2076) 늦게 깨면 밀린 분량을 한꺼번에 방출해 버스트 열차를 만든다.
# 평균 속도는 맞지만 수신측은 순간 버스트에 터지므로 천장 아래에서도 가짜 손실이
# 난다. 그래서 udp_blast 를 만들었던 것이다 (byte-budget 스핀).
#
#   -> 둘 중 하나가 "맞는" 게 아니다. 두 도구로 재서 결론이 같으면 주장이 강해진다.
#      다르면 어느 쪽이 도구 artifact 인지 따로 봐야 한다.
#
# arm 세 개. GRO 는 세 arm 모두 켜져 있다:
#   udp   iperf3 -u -w 208K  -> setsockopt(SO_RCVBUF) 호출 -> sk_rcvbuf 425984 (= 416KB)
#                              ★ -w 64M 은 쓸 수 없다: iperf3 가 rmem_max 에 잘린 것을
#                                감지하고 "socket buffer size not set correctly" 로
#                                실행을 거부한다 (iperf_udp.c:543). udp_sink 는 조용히
#                                진행하므로 이 차이가 드러나지 않았다.
#                                커널 상태(SOCK_RCVBUF_LOCK + 425984)는 양쪽 동일하므로
#                                측정 대상은 같다. 앱이 얼마를 "요청했는지"는 무관하다.
#   ours  iperf3 -u          -> -w 를 안 주면 setsockopt 를 아예 안 부른다
#                               (iperf_udp.c:501 이 조건부) -> autotune 이 동작
#   tcp   iperf3             -> tcp_rmem 기본값, DRS 동작
#
# 송신 GSO:  blksize(-l 65000) > gso_size(=MTU-28) 이므로 전 MTU 에서 켜진다.
#            iperf3 가 인터페이스 MTU 를 읽어 gso_size 를 다시 잡으므로 (iperf_udp.c:667)
#            -l 을 MTU 마다 바꿀 필요가 없다. MTU 1500 이면 44 세그먼트가 된다
#            (UDP_MAX_SEGMENTS 128 이내).
# 수신 GRO:  IPERF3_UDP_GRO 기본 ON. 앱이 setsockopt(UDP_GRO) 를 부른다 (iperf_udp.c:617)
#            ★ receiver(sslab4)에 걸어야 한다. sender 에 걸면 아무 효과 없다.
set -u
N="${1:-5}"; RATE="${2:-65}"; IF=ens81f0np0
SRV_IP=192.168.11.238; UP=5302; TP=5352
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/mtuip_${TS}; mkdir -p "$LOG"
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
echo "도구: iperf3 단일. 요청 ${RATE} Gb/s 고정, 단일 flow, GRO on (앱 setsockopt)" | tee -a "$LOG/summary.txt"
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
    ours) ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 67108864' net.core.rmem_max=212992 \
              net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
    tcp)  : ;;
  esac
}

one() {  # one <cfg> <mtu> <i>
  local cfg="$1"
  local mtu="$2"
  local i="$3"
  local d="$LOG/${cfg}_m${mtu}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  local got=""
  local tx=""
  if [ "$cfg" = tcp ]; then
    ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $TP -1" > "$d/srv.log" 2>&1 &
    local SV=$!
    sleep 2
    ssh sslab3 "taskset -c 1 $IPERF -c $SRV_IP -p $TP -b ${RATE}G -l 1M -t 11" > "$d/cli.log" 2>&1 &
  else
    # ours 만 -w 를 안 준다 -> setsockopt(SO_RCVBUF) 를 아예 안 부른다 (iperf_udp.c:501)
    local w=""
    [ "$cfg" = udp ] && w="-w 208K"
    # IPERF3_UDP_GRO 는 수신측에 걸어야 한다 (기본 ON 이지만 명시한다)
    ssh sslab4 "IPERF3_UDP_GRO=1 taskset -c 1 $IPERF -s -B $SRV_IP -p $UP -1" > "$d/srv.log" 2>&1 &
    local SV=$!
    sleep 2
    ssh sslab3 "taskset -c 1 $IPERF -c $SRV_IP -p $UP -u -b ${RATE}G -l 65000 $w -t 11" > "$d/cli.log" 2>&1 &
  fi
  ssh sslab4 "mpstat -P 1 1 9" > "$d/mp.log" 2>&1
  sleep 3; ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SV 2>/dev/null || true

  # 수신측 요약행에서 받은 쪽 수치를 쓴다. UDP 는 서버 요약에 손실률도 같이 나온다.
  got=$(grep -E 'receiver' "$d/srv.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
        | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
  tx=$(grep -E 'sender' "$d/cli.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
        | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
  local loss; loss=$(grep -oE '\([0-9.]+%\)' "$d/srv.log" 2>/dev/null | tail -1 | tr -d '()%')
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  # sender flake 배제. TCP 는 혼잡제어가 스스로 줄이는 게 정상이라 검사하지 않는다.
  local ok=1
  [ "$cfg" != tcp ] && ok=$(awk -v o="${tx:-0}" -v r="$RATE" 'BEGIN{print (o >= 0.95*r) ? 1 : 0}')
  printf "  mtu=%-5s %-5s #%-2s got=%-7s tx=%-7s loss=%-7s busy=%s%s\n" \
     "$mtu" "$cfg" "$i" "${got:-NA}" "${tx:-NA}" "${loss:-NA}%" "${busy:-NA}%" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && [ -n "${got:-}" ] && echo "$mtu $cfg $got ${tx:-0} ${busy:-0} ${loss:-0}" >> "$LOG/raw.txt"
}

for mtu in $MTUS; do
  setmtu "$mtu" || continue
  echo "===== MTU $mtu (요청 ${RATE} Gb/s) =====" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do
    for c in udp ours tcp; do one "$c" "$mtu" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 (평균±sd) ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; g[k]+=$3; gg[k]+=$3*$3; t[k]+=$4; b[k]+=$5; l[k]+=$6; n[k]++}
 END{for(k in n){split(k,x," "); mu=g[k]/n[k]; sd=sqrt(gg[k]/n[k]-mu*mu);
   printf "MTU %-5s  %-5s  got=%6.2f +-%5.2f  tx=%6.2f  loss=%5.1f%%  busy=%3.0f%%  (n=%d)\n",
   x[1],x[2],mu,sd,t[k]/n[k],l[k]/n[k],b[k]/n[k],n[k]}}' "$LOG/raw.txt" | sort -k2,2n -k4,4 | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null
    pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
