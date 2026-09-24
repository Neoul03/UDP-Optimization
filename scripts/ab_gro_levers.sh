#!/bin/bash
# ab_gro_levers.sh — 앱이 UDP_GRO 를 안 켠 경우에도 레버가 유효한가
#
# 지금까지 모든 측정이 udp_sink mode 2 (UDP_GRO sockopt 켬) 였다. 앱이 안 켜면
# udp_unexpected_gso() -> udp_rcv_segment() 가 GRO 로 합친 skb 를 **도로 datagram
# 으로 쪼갠다**. 합친 걸 푸는 것이므로 per-skb 비용이 올라가고 천장이 내려간다.
#
# 메커니즘은 GRO 와 무관하다 - autotune 은 sk_rcvbuf 만 보고 shed 는 드라이버에서
# CQE 의 L4 타입만 본다. 하지만 **동작점**(천장, 적정 버퍼, shed 윈도)은 전부
# GRO-on 에서 잰 값이다. 레버의 효과는 동작점에 따라 부호까지 바뀌므로
# (CLAUDE.md 측정 원칙 2) 그대로 옮겨 쓸 수 없다.
#
#   mode 2 = UDP_GRO 켬 (지금까지의 기준)
#   mode 0 = 평범한 recvmsg, datagram 당 한 번  <- 재분할 경로
#
#   usage: ab_gro_levers.sh [reps] [dim on|off]
set -u
N="${1:-3}"; DUR=12
SRV_IP=192.168.11.238; P=5301
DIM="${2:-on}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/grolevers_dim${DIM}_${TS}; mkdir -p "$LOG"
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show ens81f0np0" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "sudo ethtool -C ens81f0np0 adaptive-rx $DIM >/dev/null 2>&1"; sleep 2
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
# adaptive-rx 는 리부팅마다 on 으로 돌아오고 무해하지 않다. 어느 쪽인지 반드시 남긴다.
ssh sslab4 "ethtool -c ens81f0np0 | grep -E 'Adaptive RX|rx-usecs:|rx-frames:'; ethtool -g ens81f0np0 | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <label> <sink_mode> <rate> <i>
  local lbl="$1" mode="$2" b="$3" i="$4"
  local d="$LOG/${lbl}_m${mode}_b${b}_$i"; mkdir -p "$d"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P $mode $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $((DUR-2)) $b" > "$d/tx.log" 2>&1
  wait $SP $MP 2>/dev/null || true
  local got off busy avg ok
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  avg=$(grep -oE 'avg_bytes_per_call=[0-9]+' "$d/sink.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  ok=$(awk -v o="${off:-0}" -v r="$b" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  %-16s gro=%s b=%-3s #%-2s got=%-7s busy=%-4s avg=%s%s\n" \
     "$lbl" "$([ "$mode" = 2 ] && echo on || echo off)" "$b" "$i" "${got:-NA}" "${busy:-NA}%" "${avg:-NA}" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=${off}")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$lbl $mode $b ${got:-0} ${busy:-0}" >> "$LOG/raw.txt"
}

# GRO 를 끄면 천장이 내려가므로 사다리를 낮은 쪽까지 내려 잡는다. 같은 사다리로
# 두 모드를 재야 어디서 갈라지는지 보인다.
for mode in 2 0; do
  for i in $(seq 1 $N); do
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
        net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null"
    for b in 24 32 40 48 56; do one "base_noshed" "$mode" "$b" "$i"; done
    ssh sslab4 "sudo sysctl -w net.ipv4.udp_rx_shed=1 >/dev/null"
    for b in 24 32 40 48 56; do one "shed" "$mode" "$b" "$i"; done
    ssh sslab4 "sudo sysctl -w net.core.rmem_max=536870912 net.ipv4.udp_rx_shed=0 \
        net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
        net.ipv4.udp_rmem_cache_pct=50 >/dev/null"
    for b in 24 32 40 48 56; do one "autotune" "$mode" "$b" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{k=sprintf("%-14s gro=%-3s %3sG", $1, ($2==2?"on":"off"), $3); g[k]+=$4; b[k]+=$5; n[k]++}
 END{for(k in n) printf "%s  got=%6.2f  busy=%3.0f%%  (n=%d)\n", k, g[k]/n[k], b[k]/n[k], n[k]}' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
