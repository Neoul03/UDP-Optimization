#!/bin/bash
# bench_tcp_baseline.sh — 같은 조건의 TCP 를 본표에 넣는다
#
# 논문의 서사는 "UDP 는 덜 하므로 더 빨라야 하는데 그렇지 않다"에서 출발한다.
# 그러려면 **같은 코어, 같은 NIC, 같은 커널, 같은 워크로드**의 TCP 수치가
# 본표에 있어야 한다. 지금까지는 다른 실험에서 따온 값(54.34)을 인용했다.
#
# TCP 는 아무도 손대지 않아도 스스로 버퍼를 맞춘다(tcp_rcv_space_adjust).
# 그것이 이 논문이 UDP 에 없다고 지적하는 바로 그 기능이므로, 기본값으로 둔다 —
# tcp_rmem 을 제약하면 DRS 를 끄는 것이고 그 비교는 무효다(과거에 한 번 당했다).
#
#   W1  단일 연결
#   W2  8 연결
#
#   usage: bench_tcp_baseline.sh [reps]
set -u
N="${1:-10}"; DUR=12; IF=ens81f0np0
SRV_IP=192.168.11.238; BASE=5350
IPERF=~/iperf3-source/src/iperf3
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/tcpbase_${TS}; mkdir -p "$LOG"
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.tcp_rmem='4096 131072 6291456' net.core.rmem_max=6291456 >/dev/null"
echo "tcp_rmem 기본값 (DRS 활성). 제약하면 비교가 무효다." | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <dim> <wl> <i>
  local dim="$1" wl="$2" i="$3"
  local d="$LOG/${dim}_${wl}_$i"; mkdir -p "$d"
  local nc; [ "$wl" = W1 ] && nc=1 || nc=8
  local pids=""
  for f in $(seq 0 $((nc-1))); do
    ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -p $((BASE+f)) -1" > "$d/s$f.log" 2>&1 &
    pids="$pids $!"
  done
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  for f in $(seq 0 $((nc-1))); do
    ssh sslab3 "taskset -c $((f+1)) $IPERF -c $SRV_IP -p $((BASE+f)) -l 1M -t $DUR" > "$d/c$f.log" 2>&1 &
  done
  wait $MP 2>/dev/null || true
  sleep 3
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  for p in $pids; do wait $p 2>/dev/null || true; done
  # 서버 로그에서 읽는다. 서버를 죽이면 클라이언트 receiver 줄이 0 이 된다.
  local sum=0
  for f in $(seq 0 $((nc-1))); do
    local g; g=$(grep receiver "$d/s$f.log" 2>/dev/null | tail -1 | grep -oE '[0-9.]+ [GM]bits/sec' | head -1)
    local v; v=$(echo "$g" | awk '{if($2=="Mbits/sec") print $1/1000; else print $1}')
    [ -n "${v:-}" ] && sum=$(awk -v a=$sum -v x=$v 'BEGIN{print a+x}')
  done
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  printf "  dim=%-3s %s #%-2s got=%-7s busy=%s%%\n" "$dim" "$wl" "$i" "$sum" "${busy:-NA}" | tee -a "$LOG/summary.txt"
  [ -n "$sum" ] && echo "$dim $wl $sum ${busy:-0}" >> "$LOG/raw.txt"
}

for dim in on off; do
  ssh sslab4 "sudo ethtool -C $IF adaptive-rx $dim >/dev/null 2>&1"; sleep 2
  for i in $(seq 1 $N); do
    one "$dim" W1 "$i"
    one "$dim" W2 "$i"
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{k=sprintf("dim=%-3s %s", $1, $2); g[k]+=$3; b[k]+=$4; n[k]++}
 END{for(k in n) printf "%s  got=%6.2f  busy=%3.0f%%  (n=%d)\n", k, g[k]/n[k], b[k]/n[k], n[k]}' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1; sudo sysctl -w net.core.rmem_max=212992 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
