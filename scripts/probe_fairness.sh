#!/bin/bash
# probe_fairness.sh — 예산이 경쟁될 때 나중에 온 소켓이 몫을 받는가
#
# bench_two_workloads.sh 의 Jain 지수는 전 구간 0.997~1.000 으로 아무것도 구별하지
# 못했다. 8 소켓이 **동시에 시작해 같은 부하**를 받으니 대칭이고, 대칭이면 어떤
# 배분 규칙이든 같은 답을 낸다. 불공정은 비대칭에서만 드러난다.
#
# Chiu & Jain(1989): 공유 자원 + binary feedback 에서 AIMD 는 공정성과 효율성
# 모두로 수렴하고 MIMD 는 효율성으로만 수렴한다. 우리 v10/v11 은 MIMD(두 배)이고,
# 래칫 실험에서 그 결함을 이미 봤다 - 먼저 온 소켓이 8M, 나중 소켓이 2M.
#
# 여기서는 **시작 시각을 엇갈려** 그것을 지표로 만든다:
#   소켓 0 이 먼저 붙어 예산을 먹고, 2 초 간격으로 1..N-1 이 합류한다.
#   전부 같은 부하를 받으므로 이상적 배분이면 goodput 이 같아야 한다.
#
# 보는 것:
#   J        — Jain 지수 (1.0 이 완전 공정)
#   first/last — 먼저 온 소켓과 마지막 소켓의 goodput 비
#   buf      — 소켓별 rcvbuf. 래칫이 있으면 여기서 바로 보인다
#
#   usage: probe_fairness.sh [reps] [nsock] [per_socket_rate] [cache_pct]
set -u
N="${1:-5}"; NS="${2:-6}"; PER="${3:-9}"; PCT="${4:-50}"; IF=ens81f0np0
SRV_IP=192.168.11.238; BASE=5400
STAGGER=2
DUR=$(( 6 + NS*STAGGER + 10 ))
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/fair_pct${PCT}_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r; dmesg | grep -o 'receive budget sized.*' | tail -1" | tee "$LOG/summary.txt"
echo "소켓 $NS 개가 ${STAGGER}s 간격으로 합류, 각 ${PER}G. 이상적이면 전부 같은 goodput."
# 배분 규칙은 예산이 **조일 때만** 의미가 있다. pct 50 (=9MB) 에서는 6 소켓이
# 다 합쳐도 예산을 안 써서 J 가 전부 1.000 으로 나왔다. LLC 가 더 작거나 ring 이
# 더 큰 기계를 흉내내려면 pct 를 낮춘다.
echo "udp_rmem_cache_pct=$PCT (예산 = L3 의 $PCT%)" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <dim> <buf> <i>
  local dim="$1" buf="$2" i="$3"
  local d="$LOG/${dim}_${buf}_$i"; mkdir -p "$d"
  case "$buf" in
    s1M)  ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
              net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    auto) ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
              net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
              net.ipv4.udp_rmem_cache_pct=$PCT net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    auto_shed) ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
              net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
              net.ipv4.udp_rmem_cache_pct=$PCT net.ipv4.udp_rx_shed=1 >/dev/null" ;;
  esac
  local pids=""
  # 모든 소켓이 **같은 시각에 끝나야** 겹친 구간만 비교된다. 먼저 붙은 쪽은
  # 그만큼 오래 산다. goodput 은 sink 가 첫 수신부터 마지막 수신까지로 내므로
  # 합류 이전 구간이 섞이지 않도록 마지막 10 초만 겹치게 배치한다.
  for f in $(seq 0 $((NS-1))); do
    local life=$(( DUR - f*STAGGER ))
    ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $((BASE+f)) 2 $life" > "$d/s$f.log" 2>&1 &
    pids="$pids $!"
    sleep 0.3
    ssh sslab3 "taskset -c $((f+1)) /home/chanseo/udp_blast $SRV_IP $((BASE+f)) 8972 7 $((life-2)) $PER" > "$d/tx$f.log" 2>&1 &
    [ "$f" -lt $((NS-1)) ] && sleep $STAGGER
  done
  sleep 6
  local rb; rb=$(ssh sslab4 "ss -uam state unconnected 2>/dev/null | grep -oE 'rb[0-9]+' | sort -t b -k2 -n | uniq -c | tr -s ' ' | tr '\n' ' '")
  for p in $pids; do wait $p 2>/dev/null || true; done
  local gs="" sum=0 txs=0
  for f in $(seq 0 $((NS-1))); do
    local g; g=$(grep -oE 'goodput=[0-9.]+' "$d/s$f.log"|cut -d= -f2)
    [ -n "${g:-}" ] && { gs="$gs $g"; sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}'); }
    local o; o=$(grep -oE 'offered=[0-9.]+' "$d/tx$f.log"|cut -d= -f2)
    [ -n "${o:-}" ] && txs=$(awk -v a=$txs -v x=$o 'BEGIN{print a+x}')
  done
  local jain ratio
  jain=$(echo "$gs" | awk '{s=0;q=0;n=0; for(i=1;i<=NF;i++){s+=$i;q+=$i*$i;n++}
      if(n>0&&q>0) printf "%.4f", s*s/(n*q); else printf "NA"}')
  ratio=$(echo "$gs" | awk '{if(NF>1 && $NF>0) printf "%.2f", $1/$NF; else printf "NA"}')
  local ok; ok=$(awk -v o="$txs" -v r="$((NS*PER))" 'BEGIN{print (o >= 0.90*r) ? 1 : 0}')
  printf "  dim=%-3s %-9s #%-2s 합=%-7s J=%-7s first/last=%-5s buf=[%s]\n    소켓별:%s\n" \
     "$dim" "$buf" "$i" "$sum" "$jain" "$ratio" "$rb" "$gs" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$dim $buf $sum $jain $ratio" >> "$LOG/raw.txt"
}

for dim in on off; do
  ssh sslab4 "sudo ethtool -C $IF adaptive-rx $dim >/dev/null 2>&1"; sleep 2
  for buf in s1M auto auto_shed; do
    for i in $(seq 1 $N); do one "$dim" "$buf" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{k=sprintf("dim=%-3s %-9s", $1, $2); g[k]+=$3; j[k]+=$4; r[k]+=$5; n[k]++}
 END{for(k in n) printf "%s  합=%6.2f  J=%.4f  first/last=%.2f  (n=%d)\n", k, g[k]/n[k], j[k]/n[k], r[k]/n[k], n[k]}' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1; sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
