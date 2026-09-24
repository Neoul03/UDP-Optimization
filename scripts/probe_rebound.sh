#!/bin/bash
# probe_rebound.sh — 축소 경로가 "돌아오는 버스트"를 해치는가
#
# 축소의 진짜 위험은 래칫을 푸는 것이 아니라 **필요해지기 직전에** 버퍼를
# 놓는 것이다. UDP 는 sender 가 다시 올라올 것을 알려주지 않으므로 회복은
# 전적으로 성장 속도에 달렸다.
#
#   burst(RATE, 8s) -> lull(4G, lull 초) -> burst(RATE, 10s)
#                                          ^^^^^^^^^^^^^^ 이 구간만 본다
#
# 구간 분리는 sink 의 UDP_SINK_INTERVAL 누적 바이트 리포트로 한다.
# 커널 카운터로는 안 된다: rx_bytes 는 drop 된 것까지 센 선 위의 바이트이고,
# InDatagrams 는 datagram 이 아니라 GRO super-skb 를 센다.
#
# 소켓은 전 구간 하나로 유지해야 한다 - 재시작하면 버퍼가 rmem_default 로 돌아간다.
set -u
SRV_IP=192.168.11.238; P=5301; N="${1:-3}"; RATE="${2:-56}"; RB=10; B1=8
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/rebound_${RATE}G_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

rbm() { ssh sslab4 "ss -uam state unconnected sport = :$P 2>/dev/null | grep -oE 'rb[0-9]+' | head -1"; }

one() {  # one <label> <lull_s> <i>
  local lbl="$1" lull="$2" i="$3"
  local d="$LOG/${lbl}_l${lull}_$i"; mkdir -p "$d"
  local total=$(( 1 + B1 + lull + RB + 4 ))
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 UDP_SINK_INTERVAL=0.25 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 $total" \
      > "$d/sink.log" 2> "$d/iv.log" &
  local SP=$!
  sleep 1
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $B1 $RATE" >/dev/null 2>&1
  local g1; g1=$(rbm)
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $lull 4" >/dev/null 2>&1
  local g2; g2=$(rbm)
  # 복귀 버스트 시작 시각을 sink 의 시계로 잡아야 구간이 맞는다.
  local mark; mark=$(awk '{gsub(/t=/,"",$2); v=$2} END{print v+0}' "$d/iv.log")
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $RB $RATE" >/dev/null 2>&1
  local g3; g3=$(rbm)
  wait $SP 2>/dev/null || true
  # 복귀 구간: mark+0.5 부터 mark+RB-0.5 까지의 바이트 증분 (가장자리 잘라냄)
  local gbps
  gbps=$(awk -v m="$mark" -v rb="$RB" '
    {gsub(/t=/,"",$2); gsub(/bytes=/,"",$3); t[NR]=$2+0; b[NR]=$3+0}
    END{lo=m+0.5; hi=m+rb-0.5; tl=-1;
        for(i=1;i<=NR;i++){ if(t[i]>=lo && tl<0){tl=t[i]; bl=b[i]} if(t[i]<=hi){th=t[i]; bh=b[i]} }
        if(tl>=0 && th>tl) printf "%.2f", (bh-bl)*8/(th-tl)/1e9; else printf "NA"}' "$d/iv.log")
  printf "  %-8s lull=%-3s #%-2s  burst후=%-10s lull후=%-10s 복귀후=%-10s  복귀=%s Gbps\n" \
     "$lbl" "$lull" "$i" "${g1:-NA}" "${g2:-NA}" "${g3:-NA}" "$gbps" | tee -a "$LOG/summary.txt"
  echo "$lbl $lull $gbps" >> "$LOG/raw.txt"
}

for i in $(seq 1 $N); do
  for lull in 3 30; do
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
        net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
        net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=0 >/dev/null"
    one "auto" "$lull" "$i"
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
        net.ipv4.udp_rmem_autotune=0 >/dev/null"
    one "static1M" "$lull" "$i"
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=4194304 net.core.rmem_max=4194304 >/dev/null"
    one "static4M" "$lull" "$i"
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '$3!="NA"{k=$1" lull="$2; g[k]+=$3; n[k]++} END{for(k in n) printf "%-18s 복귀=%6.2f Gbps (n=%d)\n", k, g[k]/n[k], n[k]}' \
  "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
