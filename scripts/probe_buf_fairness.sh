#!/bin/bash
# probe_buf_fairness.sh — 배분 규칙을 **배분** 으로 잰다
#
# 처리량 공정성으로는 MIMD/AIMD 가 구별되지 않는다. pct 를 6 까지(예산 1.1MB) 조여도
# Jain 지수가 전부 0.999~1.000 으로 나왔다 — 성장을 거절당한 소켓들이 **애초에 그
# 버퍼가 필요 없었기** 때문이다. 9G 에 1M 이면 충분하다.
#
# 알고리즘이 실제로 통제하는 양은 처리량이 아니라 **sk_rcvbuf** 다. 래칫 실험에서
# 본 불공정(먼저 온 소켓 8M, 나중 소켓 2M)도 거기서 났다. 그러니 거기서 잰다.
#
# 조건: 소켓들이 **정말로 큰 버퍼를 원하도록** 소켓당 부하를 천장 근처로 올리고,
#       예산은 그 합을 못 대도록 조인다. 그래야 배분이 일어난다.
#
#   J_buf      = Jain 지수 over sk_rcvbuf
#   first/last = 먼저 온 소켓과 마지막 소켓의 rcvbuf 비. MIMD 면 크게 벌어진다.
#
#   usage: probe_buf_fairness.sh [reps] [nsock] [per_rate] [cache_pct]
set -u
N="${1:-5}"; NS="${2:-3}"; PER="${3:-18}"; PCT="${4:-10}"; IF=ens81f0np0
SRV_IP=192.168.11.238; BASE=5400; STAGGER=3
DUR=$(( 4 + NS*STAGGER + 12 ))
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/buffair_pct${PCT}_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r; dmesg | grep -o 'receive budget sized.*' | tail -1" | tee "$LOG/summary.txt"
echo "소켓 $NS 개 x ${PER}G, ${STAGGER}s 간격 합류, 예산 = L3 의 ${PCT}%" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <dim> <i>
  local dim="$1" i="$2"
  local d="$LOG/${dim}_$i"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
      net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
      net.ipv4.udp_rmem_cache_pct=$PCT net.ipv4.udp_rx_shed=0 >/dev/null"
  local pids=""
  for f in $(seq 0 $((NS-1))); do
    local life=$(( DUR - f*STAGGER ))
    ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $((BASE+f)) 2 $life" > "$d/s$f.log" 2>&1 &
    pids="$pids $!"
    sleep 0.3
    ssh sslab3 "taskset -c $((f+1)) /home/chanseo/udp_blast $SRV_IP $((BASE+f)) 8972 7 $((life-2)) $PER" > "$d/tx$f.log" 2>&1 &
    [ "$f" -lt $((NS-1)) ] && sleep $STAGGER
  done
  sleep 6
  # 소켓별 rcvbuf 를 **포트 순서대로** 뽑아야 first/last 가 의미를 갖는다
  local bufs=""
  for f in $(seq 0 $((NS-1))); do
    local b; b=$(ssh sslab4 "ss -uam state unconnected sport = :$((BASE+f)) 2>/dev/null | grep -oE 'rb[0-9]+' | head -1 | tr -d 'rb'")
    bufs="$bufs ${b:-0}"
  done
  local gs="" sum=0
  for p in $pids; do wait $p 2>/dev/null || true; done
  for f in $(seq 0 $((NS-1))); do
    local g; g=$(grep -oE 'goodput=[0-9.]+' "$d/s$f.log"|cut -d= -f2)
    [ -n "${g:-}" ] && { gs="$gs $g"; sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}'); }
  done
  local jb rt
  jb=$(echo "$bufs" | awk '{s=0;q=0;n=0; for(i=1;i<=NF;i++){s+=$i;q+=$i*$i;n++}
      if(n>0&&q>0) printf "%.4f", s*s/(n*q); else printf "NA"}')
  rt=$(echo "$bufs" | awk '{if(NF>1 && $NF>0) printf "%.2f", $1/$NF; else printf "NA"}')
  local mb; mb=$(echo "$bufs" | awk '{for(i=1;i<=NF;i++) printf "%.1fM ", $i/1048576}')
  printf "  dim=%-3s #%-2s J_buf=%-7s first/last=%-5s 합=%-7s  버퍼: %s\n" \
     "$dim" "$i" "$jb" "$rt" "$sum" "$mb" | tee -a "$LOG/summary.txt"
  echo "$dim $jb $rt $sum" >> "$LOG/raw.txt"
}

for dim in on off; do
  ssh sslab4 "sudo ethtool -C $IF adaptive-rx $dim >/dev/null 2>&1"; sleep 2
  for i in $(seq 1 $N); do one "$dim" "$i"; done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{j[$1]+=$2; r[$1]+=$3; g[$1]+=$4; n[$1]++}
 END{for(k in n) printf "dim=%-3s  J_buf=%.4f  first/last=%.2f  합=%6.2f  (n=%d)\n", k, j[k]/n[k], r[k]/n[k], g[k]/n[k], n[k]}' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1; sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.core.rmem_default=212992 net.core.rmem_max=212992 net.ipv4.udp_rmem_cache_pct=50 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
