#!/bin/bash
# sweep_rx_frames.sh — 붕괴의 변수는 rx-frames 이고, 버퍼가 그것을 흡수하는가
#
# 추적 결과 DIM 은 흔들리지 않는다. 즉시 rx-usecs=8 / rx-frames=128 로 정착해
# 끝까지 유지한다 (6/6 시행, 전환 0). 그런데 앞선 정적 스윕은 rx-frames 를 32 로
# 둔 채 usec 만 4~256 으로 바꿨고 전 구간 47.98 이었다 — **DIM 이 실제로 쓰는
# 지점을 한 번도 밟지 않았다.**
#
# 남은 변수는 rx-frames 뿐이다. 기전 가설:
#   rx-frames 는 인터럽트 전에 모으는 완료(CQE) 수다. 128 x 8972B = 1.15MB 가
#   한 번에 도착하는데 수신 버퍼가 1MB 면 넘친다. 32 면 287KB 라 들어간다.
#
# 이게 맞으면 두 가지가 따라온다:
#   1. rx-frames 만 바꿔도 DIM 없이 붕괴가 재현된다
#   2. **버퍼를 키우면 흡수된다** — 필요한 버퍼 크기가 인터럽트 모더레이션의
#      함수라는 뜻이고, 그 값은 앱도 관리자도 볼 수 없으며 DIM 이 런타임에 정한다
#
# usage: sweep_rx_frames.sh [reps] [rate]
set -u
N="${1:-3}"; RATE="${2:-48}"; DUR=12; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/rxframes_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
echo "rate=${RATE}G  adaptive-rx off, rx-usecs 8 고정 (DIM 이 정착한 값), rx-frames 만 스윕" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <buf> <frames> <i>
  local buf="$1" fr="$2" i="$3"
  local d="$LOG/${buf}_f${fr}_$i"; mkdir -p "$d"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $((DUR-2)) $RATE" > "$d/tx.log" 2>&1
  wait $SP $MP 2>/dev/null || true
  local got off busy ok rb
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  ok=$(awk -v o="${off:-0}" -v r="$RATE" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  %-9s frames=%-4s #%-2s got=%-7s busy=%s%%%s\n" "$buf" "$fr" "$i" "${got:-NA}" "${busy:-NA}" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=${off}")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$buf $fr ${got:-0} ${busy:-0}" >> "$LOG/raw.txt"
}

ssh sslab4 "sudo ethtool -C $IF adaptive-rx off >/dev/null 2>&1"; sleep 1
ssh sslab4 "sudo ethtool -C $IF rx-usecs 8 >/dev/null 2>&1"; sleep 1
for buf in fixed1M fixed8M autotune; do
  case "$buf" in
    fixed1M)  ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
                  net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    fixed8M)  ssh sslab4 "sudo sysctl -w net.core.rmem_default=8388608 net.core.rmem_max=8388608 \
                  net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    autotune) ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
                  net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
                  net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
  esac
  for fr in 16 32 64 96 128 192 256; do
    ssh sslab4 "sudo ethtool -C $IF rx-frames $fr >/dev/null 2>&1"; sleep 1
    for i in $(seq 1 $N); do one "$buf" "$fr" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; s[k]+=$3; ss[k]+=$3*$3; b[k]+=$4; n[k]++}
 END{for(k in n){m=s[k]/n[k]; v=ss[k]/n[k]-m*m; sd=(v>0)?sqrt(v):0; split(k,a," ");
   printf "%-9s frames=%-4s 평균=%6.2f  sd=%5.2f  busy=%3.0f%%  (n=%d)\n", a[1], a[2], m, sd, b[k]/n[k], n[k]}}' \
 "$LOG/raw.txt" | sort -k1,1 -k2.8n | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1; sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
