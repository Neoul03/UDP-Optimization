#!/bin/bash
# bench_grid.sh — MTU x flow 수 격자로 네 설정을 비교
#
# 축:
#   MTU    1500 / 3000 / 4500 / 6000 / 7500 / 9000
#   flow   1 / 2 / 4 / 8 / 16      (소켓 수. 전부 같은 코어에서 돈다)
#
# 설정:
#   udp_plain    앱이 setsockopt 를 안 부름           -> 208KB
#   udp_sockopt  앱이 SO_RCVBUF 64MB 를 요청          -> 416KB 로 조용히 잘림
#                (rmem_max 기본값이 208KB 이고 커널이 2 배를 주기 때문)
#                이쪽이 **현실적인 기준선**이다. 고속 UDP 앱은 보통 이걸 부른다.
#   udp_ours     우리 것 (sizing + cap + 폐기)
#   tcp          기존 TCP. tcp_rmem 은 건드리지 않는다.
#
# 제공률은 MTU 마다 다르다. 작은 MTU 는 per-packet 비용이 지배해 sender 가 낼 수
# 있는 양부터 다르므로, MTU 별로 sender 최대치를 먼저 재고 그 90% 를 쓴다.
# 그래야 **수신측 한계**를 재는 것이지 sender 한계를 재는 것이 아니게 된다.
set -u
N="${1:-5}"; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301; BASE=5400
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/grid_${TS}; mkdir -p "$LOG"
MTUS="1500 3000 4500 6000 7500 9000"
FLOWS="1 2 4 8 16"

TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
# 단일코어 방법론
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "sudo ethtool -G $IF rx 128 >/dev/null 2>&1"; sleep 4
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1"
ssh sslab4 "echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null"
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

setmtu() {
  ssh sslab4 "sudo ip link set $IF mtu $1"; ssh sslab3 "sudo ip link set $IF mtu $1"; sleep 3
  local a b
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
  local cfg="$1" mtu="$2" nf="$3" rate="$4" i="$5"
  local d="$LOG/m${mtu}_f${nf}_${cfg}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  local pids="" env=""
  [ "$cfg" = udp_sockopt ] && env="UDP_SINK_RCVBUF=67108864" || env="UDP_SINK_NO_RCVBUF=1"
  if [ "$cfg" = tcp ]; then
    for f in $(seq 0 $((nf-1))); do
      ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $((5350+f)) -1" > "$d/b$f.log" 2>&1 &
      pids="$pids $!"
    done
    sleep 2
    for f in $(seq 0 $((nf-1))); do
      ssh sslab3 "taskset -c $(( (f % 20) + 1 )) $IPERF -c $SRV_IP -p $((5350+f)) -l 1M -t 11" > "$d/c$f.log" 2>&1 &
    done
  else
    local pl; pl=$(payload "$mtu")
    for f in $(seq 0 $((nf-1))); do
      local port; [ "$nf" = 1 ] && port=$P || port=$((BASE+f))
      ssh sslab4 "$env taskset -c 1 /home/chanseo/udp_sink $SRV_IP $port 2 12" > "$d/b$f.log" 2>&1 &
      pids="$pids $!"
    done
    sleep 1
    for f in $(seq 0 $((nf-1))); do
      local port; [ "$nf" = 1 ] && port=$P || port=$((BASE+f))
      ssh sslab3 "taskset -c $(( (f % 20) + 1 )) timeout 16 /home/chanseo/udp_blast $SRV_IP $port $pl 7 10 $rate" > "$d/tx$f.log" 2>&1 &
    done
  fi
  ssh sslab4 "mpstat -P 1 1 9" > "$d/mp.log" 2>&1 &
  local MP=$!
  wait $MP 2>/dev/null || true
  [ "$cfg" = tcp ] && { sleep 3; ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"; }
  for p in $pids; do wait $p 2>/dev/null || true; done

  local sum=0 txs=0
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
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  local ok=1
  [ "$cfg" != tcp ] && ok=$(awk -v o="$txs" -v r="$((nf*rate))" 'BEGIN{print (o >= 0.90*r) ? 1 : 0}')
  printf "  mtu=%-5s f=%-2s %-12s #%-2s got=%-7s busy=%-4s tx=%s%s\n" \
     "$mtu" "$nf" "$cfg" "$i" "$sum" "${busy:-NA}%" "$txs" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$mtu $nf $cfg $sum ${busy:-0}" >> "$LOG/raw.txt"
}

for mtu in $MTUS; do
  setmtu "$mtu" || continue
  SMAX=$(probe_sender "$mtu")
  TOT=$(awk -v s="${SMAX:-30}" 'BEGIN{printf "%d", s*0.9}')
  echo "===== MTU $mtu  (sender 최대 ${SMAX:-?} -> 제공 ${TOT}G) =====" | tee -a "$LOG/summary.txt"
  for nf in $FLOWS; do
    RATE=$(( TOT / nf )); [ "$RATE" -lt 1 ] && RATE=1
    for i in $(seq 1 $N); do
      for c in udp_plain udp_sockopt udp_ours tcp; do one "$c" "$mtu" "$nf" "$RATE" "$i"; done
    done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 격자 요약 ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2" "$3; g[k]+=$4; b[k]+=$5; n[k]++}
 END{for(k in n){split(k,x," "); printf "MTU %-5s flows %-3s %-12s got=%6.2f  busy=%3.0f%%  (n=%d)\n",
   x[1],x[2],x[3],g[k]/n[k],b[k]/n[k],n[k]}}' "$LOG/raw.txt" | sort -k2,2n -k4,4n -k5,5 | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null; pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
