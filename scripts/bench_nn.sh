#!/bin/bash
# bench_nn.sh — "sender 가 여러 명" 과 "n:n" 을 분리해서 잰다.
#
# 두 모드가 **딱 하나만** 다르다: 수신 소켓이 1 개냐 N 개냐.
# sender 쪽은 두 모드가 완전히 동일하다 (N 개 udp_blast, N 개 코어, 같은 총 제공률).
# 그래야 차이를 수신 소켓 수 탓으로 돌릴 수 있다.
#
#   mode=fanin   N sender  →  **수신 소켓 1 개**   (다수 sender 가 한 소켓에 꽂힘)
#   mode=nn      N sender  →  **수신 소켓 N 개**   (1:1 이 N 쌍)
#
# TCP 는 fanin 을 할 수 없다 — 연결마다 소켓이 따로 생기는 게 프로토콜 정의다.
# 그래서 TCP 행은 두 모드에서 **같은 실험**이고, 그것 자체가 논지다:
# "다수 sender → 소켓 하나" 는 UDP 에만 있는 경우다. 그래프에 각주로 남길 것.
#
# 설정 네 개는 grid2 와 동일:
#   udp_plain    setsockopt 안 부름        -> 208KB
#   udp_sockopt  SO_RCVBUF 64MB 요청       -> rmem_max 에 막혀 416KB
#   udp_ours     autotune=1 cache_pct=50 shed=1   (전 칸 고정)
#   tcp          tcp_rmem 은 건드리지 않는다
#
# 지연: 네 조건 모두에 동일한 저속 프로브(1000pps, 64B)를 벌크 옆에 흘린다.
# 프로브는 측정 대상이 아니라 자(尺)다.
set -u
N="${1:-5}"; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301; BASE=5400; PP=5399
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/nn_${TS}; mkdir -p "$LOG"
COUNTS="1 2 4 8 16"

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
[ "$CH" = 1 ] || { echo "FATAL combined=$CH (단일코어 아님)"; exit 1; }
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'; ethtool -c $IF | grep -i adaptive" | tee "$LOG/summary.txt"
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

probe_sender() {  # probe_sender <mtu>
  local pl; pl=$(payload "$1")
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 8" >/dev/null 2>&1 &
  local SP=$!
  sleep 1
  local out; out=$(ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P $pl 7 6 0" 2>/dev/null)
  wait $SP 2>/dev/null || true
  echo "$out" | grep -oE 'offered=[0-9.]+' | cut -d= -f2
}

one() {  # one <mode> <cfg> <mtu> <nsend> <rate_each> <i>
  local mode="$1"
  local cfg="$2"
  local mtu="$3"
  local ns="$4"
  local rate="$5"
  local i="$6"
  local d="$LOG/${mode}_m${mtu}_n${ns}_${cfg}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  # 수신 소켓 수: fanin 은 언제나 1, nn 은 sender 수와 같다
  local nsock=$ns; [ "$mode" = fanin ] && nsock=1

  ssh sslab4 "taskset -c 1 /home/chanseo/udp_ping -s $SRV_IP $PP 18" > "$d/psrv.log" 2>&1 &
  local PS=$!
  sleep 1
  local pids=""
  if [ "$cfg" = tcp ]; then
    # TCP 는 연결마다 소켓이 따로 생긴다. fanin 을 할 방법이 없으므로 두 모드가 같다.
    for f in $(seq 0 $((ns-1))); do
      ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $((5350+f)) -1" > "$d/b$f.log" 2>&1 &
      pids="$pids $!"
    done
    sleep 2
    for f in $(seq 0 $((ns-1))); do
      ssh sslab3 "taskset -c $(( (f % 18) + 1 )) $IPERF -c $SRV_IP -p $((5350+f)) -l 1M -t 12" > "$d/c$f.log" 2>&1 &
    done
  else
    local pl; pl=$(payload "$mtu")
    local env
    [ "$cfg" = udp_sockopt ] && env="UDP_SINK_RCVBUF=67108864" || env="UDP_SINK_NO_RCVBUF=1"
    for s in $(seq 0 $((nsock-1))); do
      local port; [ "$nsock" = 1 ] && port=$P || port=$((BASE+s))
      ssh sslab4 "$env taskset -c 1 /home/chanseo/udp_sink $SRV_IP $port 2 14" > "$d/b$s.log" 2>&1 &
      pids="$pids $!"
    done
    sleep 1
    # sender 는 두 모드가 동일하다: N 개 프로세스, N 개 코어, 각 rate.
    # 다른 것은 목적지 포트뿐 — fanin 이면 전부 같은 포트로 간다.
    for f in $(seq 0 $((ns-1))); do
      local port
      if [ "$mode" = fanin ]; then port=$P
      else [ "$ns" = 1 ] && port=$P || port=$((BASE+f)); fi
      ssh sslab3 "taskset -c $(( (f % 18) + 1 )) timeout 18 /home/chanseo/udp_blast $SRV_IP $port $pl 7 12 $rate" > "$d/tx$f.log" 2>&1 &
    done
  fi
  sleep 2
  ssh sslab3 "taskset -c 21 /home/chanseo/udp_ping -c $SRV_IP $PP 8 1000" > "$d/ping.log" 2>&1
  wait $PS 2>/dev/null || true
  [ "$cfg" = tcp ] && { sleep 3; ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"; }
  for p in $pids; do wait $p 2>/dev/null || true; done

  local sum=0
  local txs=0
  if [ "$cfg" = tcp ]; then
    for f in $(seq 0 $((ns-1))); do
      local g; g=$(grep receiver "$d/b$f.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1 \
                   | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
      [ -n "${g:-}" ] && sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}')
    done
  else
    for s in $(seq 0 $((nsock-1))); do
      local g; g=$(grep -oE 'goodput=[0-9.]+' "$d/b$s.log"|cut -d= -f2)
      [ -n "${g:-}" ] && sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}')
    done
    for f in $(seq 0 $((ns-1))); do
      local o; o=$(grep -oE 'offered=[0-9.]+' "$d/tx$f.log" 2>/dev/null|cut -d= -f2)
      [ -n "${o:-}" ] && txs=$(awk -v a=$txs -v x=$o 'BEGIN{print a+x}')
    done
  fi
  local L; L=$(grep -oE 'loss=[0-9.]+% mean=[0-9.]+ p50=[0-9.]+ p99=[0-9.]+ p999=[0-9.]+ max=[0-9.]+' "$d/ping.log" \
               | sed -E 's/[a-z0-9]*=//g')
  local pl_; pl_=$(echo "$L" | awk '{print $1+0}')
  local p50; p50=$(echo "$L" | awk '{print $3+0}')
  local p99; p99=$(echo "$L" | awk '{print $4+0}')
  local ok=1
  [ "$cfg" != tcp ] && ok=$(awk -v o="$txs" -v r="$((ns*rate))" 'BEGIN{print (o >= 0.90*r) ? 1 : 0}')
  printf "  %-5s mtu=%-5s n=%-2s %-12s #%-2s got=%-7s p50=%-7s p99=%-8s probe_loss=%s%s\n" \
     "$mode" "$mtu" "$ns" "$cfg" "$i" "$sum" "${p50:-0}" "${p99:-0}" "${pl_:-0}%" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=$txs")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$mode $mtu $ns $cfg $sum ${p50:-0} ${p99:-0} ${pl_:-0}" >> "$LOG/raw.txt"
}

for mtu in 1500 9000; do
  setmtu "$mtu" || continue
  SMAX=$(probe_sender "$mtu")
  TOT=$(awk -v s="${SMAX:-30}" 'BEGIN{printf "%d", s*0.9}')
  echo "===== MTU $mtu  (sender 최대 ${SMAX:-?} -> 제공 ${TOT}G) =====" | tee -a "$LOG/summary.txt"
  for ns in $COUNTS; do
    RATE=$(( TOT / ns )); [ "$RATE" -lt 1 ] && RATE=1
    for i in $(seq 1 $N); do
      # 두 모드를 시행 안에서 번갈아 돌려 시간 드리프트가 한쪽에만 쌓이지 않게 한다
      for mode in fanin nn; do
        for c in udp_plain udp_sockopt udp_ours tcp; do one "$mode" "$c" "$mtu" "$ns" "$RATE" "$i"; done
      done
    done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2" "$3" "$4; g[k]+=$5; a[k]+=$6; b[k]+=$7; l[k]+=$8; n[k]++}
 END{for(k in n){split(k,x," "); printf "%-5s MTU %-5s n %-3s %-12s got=%6.2f  p50=%7.1f  p99=%8.1f  probe_loss=%5.2f%%  (n=%d)\n",
   x[1],x[2],x[3],x[4],g[k]/n[k],a[k]/n[k],b[k]/n[k],l[k]/n[k],n[k]}}' "$LOG/raw.txt" \
 | sort -k1,1 -k3,3n -k5,5n -k6,6 | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null; pgrep -a 'udp_sink|udp_ping|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
