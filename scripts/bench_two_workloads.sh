#!/bin/bash
# bench_two_workloads.sh — 하나의 설정으로 두 워크로드를 동시에 만족시킬 수 있는가
#
# 앞선 실험에서 소켓 수와 소켓당 부하를 같이 바꿔놓고 "소켓 수 축"으로 읽을 뻔했다.
# 둘은 축이 아니라 **서로 다른 두 워크로드**이고, 그게 오히려 논지다:
#
#   W1  소켓 1개 x 56G   — 버스트 지배. 버퍼가 모더레이션 창을 담아야 한다.
#                          작은 버퍼가 진다.
#   W2  소켓 8개 x 7G    — 워킹셋 지배. 소켓당 부하는 낮지만 정적 8M 은 부하와
#                          무관하게 8 x 8M = 64MB 를 **쥐고 있다** (L3 의 3.5배).
#                          큰 버퍼가 진다.
#
# 여기에 모더레이션 축(DIM on/off)을 곱한다. DIM 은 버스트 크기를 바꾸는데
# 앱은 그 값을 볼 수 없다.
#
# W2 에서는 **Jain 공정성 지수**도 같이 낸다. 현재 성장 규칙은 MIMD(두 배로 키움)이고,
# Chiu & Jain 은 MIMD 가 효율로는 수렴해도 공정성으로는 수렴하지 않음을 보였다.
# AIMD 로 바꾸기 전의 기준선을 여기서 잡아둔다.
#   J = (Σx)^2 / (n · Σx^2),  1.0 이 완전 공정
#
#   usage: bench_two_workloads.sh [reps]
set -u
N="${1:-5}"; DUR=12; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301; BASE=5400
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/twowl_${TS}; mkdir -p "$LOG"
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r; dmesg | grep -o 'receive budget sized.*' | tail -1; \
  ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

setbuf() {
  case "$1" in
    s1M)  ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
              net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    s8M)  ssh sslab4 "sudo sysctl -w net.core.rmem_default=8388608 net.core.rmem_max=8388608 \
              net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    auto) ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
              net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
              net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    auto_shed) ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
              net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
              net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
  esac
}

one() {  # one <dim> <buf> <wl W1|W2> <i>
  local dim="$1" buf="$2" wl="$3" i="$4"
  local d="$LOG/${dim}_${buf}_${wl}_$i"; mkdir -p "$d"
  local ns per
  if [ "$wl" = W1 ]; then ns=1; per=56; else ns=8; per=7; fi
  local pids=""
  for f in $(seq 0 $((ns-1))); do
    local pt; [ "$ns" = 1 ] && pt=$P || pt=$((BASE+f))
    ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $pt 2 $DUR" > "$d/s$f.log" 2>&1 &
    pids="$pids $!"
  done
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  for f in $(seq 0 $((ns-1))); do
    local pt; [ "$ns" = 1 ] && pt=$P || pt=$((BASE+f))
    ssh sslab3 "taskset -c $((f+1)) /home/chanseo/udp_blast $SRV_IP $pt 8972 7 $((DUR-2)) $per" > "$d/tx$f.log" 2>&1 &
  done
  # 소켓이 살아 있는 동안 버퍼를 읽어야 한다. 끝난 뒤 읽으면 닫힌 소켓을 못 본다.
  sleep $((DUR-4))
  local rb; rb=$(ssh sslab4 "ss -uam state unconnected 2>/dev/null | grep -oE 'rb[0-9]+' | sort -t b -k2 -n | uniq -c | tr -s ' ' | tr '\n' ' '")
  wait $MP 2>/dev/null || true
  for p in $pids; do wait $p 2>/dev/null || true; done
  # 소켓별 goodput 을 모아 합계와 Jain 지수를 낸다
  local gs=""; local sum=0 txs=0
  for f in $(seq 0 $((ns-1))); do
    local g; g=$(grep -oE 'goodput=[0-9.]+' "$d/s$f.log"|cut -d= -f2)
    [ -n "${g:-}" ] && { gs="$gs $g"; sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}'); }
    local o; o=$(grep -oE 'offered=[0-9.]+' "$d/tx$f.log"|cut -d= -f2)
    [ -n "${o:-}" ] && txs=$(awk -v a=$txs -v x=$o 'BEGIN{print a+x}')
  done
  local jain; jain=$(echo "$gs" | awk '{s=0;q=0;n=0; for(i=1;i<=NF;i++){s+=$i;q+=$i*$i;n++}
      if(n>0 && q>0) printf "%.4f", s*s/(n*q); else printf "NA"}')
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  local tot; tot=$(awk -v n="$ns" -v p="$per" 'BEGIN{printf "%.0f", n*p}')
  local ok; ok=$(awk -v o="$txs" -v r="$tot" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  dim=%-3s %-9s %s #%-2s got=%-7s busy=%-4s J=%-7s buf=[%s]%s\n" \
     "$dim" "$buf" "$wl" "$i" "$sum" "${busy:-NA}%" "$jain" "$rb" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=$txs")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$dim $buf $wl $sum ${busy:-0} ${jain:-0}" >> "$LOG/raw.txt"
}

for dim in on off; do
  ssh sslab4 "sudo ethtool -C $IF adaptive-rx $dim >/dev/null 2>&1"; sleep 2
  for buf in s1M s8M auto auto_shed; do
    setbuf "$buf"
    for i in $(seq 1 $N); do
      one "$dim" "$buf" W1 "$i"
      one "$dim" "$buf" W2 "$i"
    done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "W1 = 1소켓x56G (버스트 지배)   W2 = 8소켓x7G (워킹셋 지배)" | tee -a "$LOG/summary.txt"
awk '{k=sprintf("dim=%-3s %-9s %s", $1, $2, $3); g[k]+=$4; b[k]+=$5; j[k]+=$6; n[k]++}
 END{for(k in n) printf "%s  got=%6.2f  busy=%3.0f%%  J=%.4f  (n=%d)\n", k, g[k]/n[k], b[k]/n[k], j[k]/n[k], n[k]}' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1; sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
