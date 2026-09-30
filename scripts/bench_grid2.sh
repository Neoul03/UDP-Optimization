#!/bin/bash
# bench_grid2.sh — 처리량과 지연을 **같은 실행에서** 잰다. 네 설정 x 두 축.
#
# 축 A (MTU 축):   MTU 1500..9000 (1500 간격), flow 1 고정
# 축 B (flow 축):  flow 1/2/4/8/16, MTU 1500 과 9000 각각 고정
#   -> 두 축의 flow=1 칸이 겹치므로 격자는 6 + 2x4 = 14 칸.
#
# 설정 (우리 쪽은 14 칸 내내 하나로 고정한다. 칸마다 손보지 않는 것이 요점):
#   udp_plain    앱이 setsockopt 를 안 부름          -> 208KB
#   udp_sockopt  SO_RCVBUF 64MB 요청                 -> rmem_max 기본값에 막혀 416KB
#   udp_ours     autotune=1 cache_pct=50 shed=1
#   tcp          기존 TCP. tcp_rmem 은 건드리지 않는다.
#
# 지연: 네 조건 모두에 **동일한** 저속 프로브(1000pps, 64B)를 벌크 부하 옆에
# 흘려 왕복을 잰다. 프로브는 측정 대상이 아니라 자(尺)이고 바뀌는 것은 옆에서
# 도는 벌크뿐이다. 그래서 TCP 와 UDP 를 같은 자로 비교할 수 있다. 에코 서버는
# 벌크 소비자와 같은 코어에서 돌린다 — 응답할 여유가 없는 수신기가 증상이다.
# 프로브 자체의 손실도 기록한다: shed 는 프로브를 가리지 않고 버리므로 그 비용이
# 여기서 보여야 한다.
#
# 제공률은 MTU 마다 다르다. 작은 MTU 는 per-packet 비용이 sender 를 먼저 묶으므로
# MTU 별로 sender 최대치를 무페이싱으로 재고 그 90% 를 쓴다 — 그래야 **수신측**
# 한계를 재는 것이 된다.
set -u
N="${1:-5}"; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301; BASE=5400; PP=5399
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/grid2_${TS}; mkdir -p "$LOG"

TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
# 단일코어 방법론: 큐 하나, IRQ 를 cpu1 에 못박고 소비자도 같은 코어.
# 멀티 플로우는 소켓을 여러 개 두지만 전부 같은 코어에서 돈다.
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "sudo ethtool -G $IF rx 128 >/dev/null 2>&1"; sleep 4
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1"; sleep 2
# governor 는 세팅하지 않고 확인만 한다. glob 으로 sudo tee 하는 형태가
# permission classifier 에 걸리고, 이 호스트는 이미 performance 다.
GOV=$(ssh sslab4 "cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor")
[ "$GOV" = performance ] || { echo "FATAL governor=$GOV (performance 여야 한다)"; exit 1; }
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH (단일코어 아님)"; exit 1; }
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'; ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \"combined \" \$2; exit}'; ethtool -c $IF | grep -i adaptive-rx" | tee "$LOG/summary.txt"
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
    udp_plain|udp_sockopt)
      ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
          net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    udp_ours)
      ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 67108864' net.core.rmem_max=212992 \
          net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
    tcp) : ;;
  esac
}
payload() { echo $(( $1 - 28 )); }

# MTU 별 sender 최대치. 무페이싱으로 한 번 재서 sender 한계를 알아둔다.
probe_sender() {  # probe_sender <mtu>
  local pl; pl=$(payload "$1")
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 8" >/dev/null 2>&1 &
  local SP=$!
  sleep 1
  local out; out=$(ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P $pl 7 6 0" 2>/dev/null)
  wait $SP 2>/dev/null || true
  echo "$out" | grep -oE 'offered=[0-9.]+' | cut -d= -f2
}

one() {  # one <cfg> <mtu> <nflow> <rate_each> <i>
  local cfg="$1"
  local mtu="$2"
  local nf="$3"
  local rate="$4"
  local i="$5"
  local d="$LOG/m${mtu}_f${nf}_${cfg}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  # 프로브 에코 서버: 전 조건 동일, 벌크 소비자와 같은 코어
  ssh sslab4 "taskset -c 1 /home/chanseo/udp_ping -s $SRV_IP $PP 18" > "$d/psrv.log" 2>&1 &
  local PS=$!
  sleep 1
  local pids=""
  if [ "$cfg" = tcp ]; then
    for f in $(seq 0 $((nf-1))); do
      ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $((5350+f)) -1" > "$d/b$f.log" 2>&1 &
      pids="$pids $!"
    done
    sleep 2
    for f in $(seq 0 $((nf-1))); do
      ssh sslab3 "taskset -c $(( (f % 18) + 1 )) $IPERF -c $SRV_IP -p $((5350+f)) -l 1M -t 12" > "$d/c$f.log" 2>&1 &
    done
  else
    local pl; pl=$(payload "$mtu")
    local env
    [ "$cfg" = udp_sockopt ] && env="UDP_SINK_RCVBUF=67108864" || env="UDP_SINK_NO_RCVBUF=1"
    for f in $(seq 0 $((nf-1))); do
      local port; [ "$nf" = 1 ] && port=$P || port=$((BASE+f))
      ssh sslab4 "$env taskset -c 1 /home/chanseo/udp_sink $SRV_IP $port 2 14" > "$d/b$f.log" 2>&1 &
      pids="$pids $!"
    done
    sleep 1
    for f in $(seq 0 $((nf-1))); do
      local port; [ "$nf" = 1 ] && port=$P || port=$((BASE+f))
      ssh sslab3 "taskset -c $(( (f % 18) + 1 )) timeout 18 /home/chanseo/udp_blast $SRV_IP $port $pl 7 12 $rate" > "$d/tx$f.log" 2>&1 &
    done
  fi
  sleep 2
  # 프로브 클라이언트는 sender 의 벌크 코어와 겹치지 않는 코어에서
  ssh sslab3 "taskset -c 21 /home/chanseo/udp_ping -c $SRV_IP $PP 8 1000" > "$d/ping.log" 2>&1
  wait $PS 2>/dev/null || true
  [ "$cfg" = tcp ] && { sleep 3; ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"; }
  for p in $pids; do wait $p 2>/dev/null || true; done

  local sum=0
  local txs=0
  for f in $(seq 0 $((nf-1))); do
    if [ "$cfg" = tcp ]; then
      local g; g=$(grep receiver "$d/b$f.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
                   | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
      [ -n "${g:-}" ] && sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}')
    else
      local g; g=$(grep -oE 'goodput=[0-9.]+' "$d/b$f.log"|cut -d= -f2)
      [ -n "${g:-}" ] && sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}')
      local o; o=$(grep -oE 'offered=[0-9.]+' "$d/tx$f.log" 2>/dev/null|cut -d= -f2)
      [ -n "${o:-}" ] && txs=$(awk -v a=$txs -v x=$o 'BEGIN{print a+x}')
    fi
  done
  # 지연. 'p50=41.1' 에서 값만 남긴다 — tr -d 'a-z=%' 는 키 안의 숫자(50)를 남겨
  # 값에 붙여버린다 (과거에 p50 > max 가 나온 원인).
  local L; L=$(grep -oE 'loss=[0-9.]+% mean=[0-9.]+ p50=[0-9.]+ p99=[0-9.]+ p999=[0-9.]+ max=[0-9.]+' "$d/ping.log" \
               | sed -E 's/[a-z0-9]*=//g')
  local pl_; pl_=$(echo "$L" | awk '{print $1+0}')
  local p50; p50=$(echo "$L" | awk '{print $3+0}')
  local p99; p99=$(echo "$L" | awk '{print $4+0}')
  local ok=1
  [ "$cfg" != tcp ] && ok=$(awk -v o="$txs" -v r="$((nf*rate))" 'BEGIN{print (o >= 0.90*r) ? 1 : 0}')
  printf "  mtu=%-5s f=%-2s %-12s #%-2s got=%-7s p50=%-7s p99=%-8s probe_loss=%s%s\n" \
     "$mtu" "$nf" "$cfg" "$i" "$sum" "${p50:-0}" "${p99:-0}" "${pl_:-0}%" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=$txs")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$mtu $nf $cfg $sum ${p50:-0} ${p99:-0} ${pl_:-0}" >> "$LOG/raw.txt"
}

# MTU 마다 어떤 flow 수를 돌릴지. 1500/9000 만 flow 축 전체를 돈다.
flows_for() { case "$1" in 1500|9000) echo "1 2 4 8 16";; *) echo "1";; esac; }

for mtu in 1500 3000 4500 6000 7500 9000; do
  setmtu "$mtu" || continue
  SMAX=$(probe_sender "$mtu")
  TOT=$(awk -v s="${SMAX:-30}" 'BEGIN{printf "%d", s*0.9}')
  echo "===== MTU $mtu  (sender 최대 ${SMAX:-?} -> 제공 ${TOT}G) =====" | tee -a "$LOG/summary.txt"
  for nf in $(flows_for "$mtu"); do
    RATE=$(( TOT / nf )); [ "$RATE" -lt 1 ] && RATE=1
    for i in $(seq 1 $N); do
      for c in udp_plain udp_sockopt udp_ours tcp; do one "$c" "$mtu" "$nf" "$RATE" "$i"; done
    done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2" "$3; g[k]+=$4; a[k]+=$5; b[k]+=$6; l[k]+=$7; n[k]++}
 END{for(k in n){split(k,x," "); printf "MTU %-5s flows %-3s %-12s got=%6.2f  p50=%7.1f  p99=%8.1f  probe_loss=%5.2f%%  (n=%d)\n",
   x[1],x[2],x[3],g[k]/n[k],a[k]/n[k],b[k]/n[k],l[k]/n[k],n[k]}}' "$LOG/raw.txt" \
 | sort -k2,2n -k4,4n -k5,5 | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null; pgrep -a 'udp_sink|udp_ping|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
