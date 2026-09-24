#!/bin/bash
# bench_final.sh — 종합 성능 측정
#
# 지금까지 찾은 레버를 하나씩 쌓아가며 재고, TCP 를 같은 조건에서 함께 잰다.
# 모든 arm 은 같은 커널(6.18.53-udpopt9)에서 sysctl/ethtool 만 달리한다 -
# 커널을 바꿔가며 비교하면 config 드리프트가 섞인다.
#
# 측정 도구: udp_blast(byte-budget pacing) -> udp_sink.
#   iperf3 는 -b pacing 이 천장 아래에서 가짜 손실을 만들어 쓰지 않는다.
#   TCP 만 iperf3 로 재고, tcp_rmem 은 **기본값**을 쓴다(제약하면 DRS 를 끈 것).
#
# 세 시나리오:
#   A. 단일 흐름 사다리 — 천장이 어디인가
#   B. 8 소켓          — 전역 예산이 필요한 조건
#   C. 과부하          — shed 가 붕괴를 막는가
set -u
N="${1:-5}"; DUR=12; IF=ens81f0np0
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/final_${TS}; mkdir -p "$LOG"
SRV_IP=192.168.11.238; PORT=5301; BASE=5400
IPERF=~/iperf3-source/src/iperf3

# ---- 전제 assert ----
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%) - 빌드 중인가?"; exit 1; }
ssh sslab4 "uname -r; dmesg | grep -o 'receive budget sized.*' | tail -1" | tee "$LOG/verify.log"
: > "$LOG/raw.txt"

# sysctl 묶음. ring 은 별도로 설정한다(복합 sudo 블록이 classifier 에 걸림).
sc() { ssh sslab4 "sudo sysctl -w $* >/dev/null"; }
setring() { ssh sslab4 "sudo ethtool -G $IF rx $1 >/dev/null 2>&1; sleep 3; sudo ethtool -L $IF combined 1 >/dev/null 2>&1; sleep 2"; ssh sslab4 "for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done"; }

udp1() {  # udp1 <label> <rate> <i>   단일 소켓
  local lbl="$1" b="$2" i="$3"
  local d="$LOG/${lbl}_b${b}_$i"; mkdir -p "$d"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $PORT 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PORT 8972 7 $((DUR-2)) $b" > "$d/blast.log" 2>&1 || true
  wait $SP $MP 2>/dev/null || true
  local got busy off
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/blast.log" | cut -d= -f2)
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  [ -z "${got:-}" ] && return
  printf "  %-14s b=%-3s #%-2s got=%-7s busy=%s%%\n" "$lbl" "$b" "$i" "$got" "${busy:-NA}" | tee -a "$LOG/summary.txt"
  echo "$lbl $b $got ${busy:-0}" >> "$LOG/raw.txt"
}

udp8() {  # udp8 <label> <total_rate> <i>   8 소켓
  local lbl="$1" tot="$2" i="$3"
  local per; per=$(awk -v t="$tot" 'BEGIN{printf "%.2f", t/8}')
  local d="$LOG/${lbl}_b${tot}_$i"; mkdir -p "$d"
  local pids=""
  for f in $(seq 0 7); do
    ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $((BASE+f)) 2 $DUR" > "$d/s$f.log" 2>&1 &
    pids="$pids $!"
  done
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  for f in $(seq 0 7); do
    ssh sslab3 "taskset -c $((f+1)) /home/chanseo/udp_blast $SRV_IP $((BASE+f)) 8972 7 $((DUR-2)) $per" >/dev/null 2>&1 &
  done
  wait $MP 2>/dev/null || true
  for p in $pids; do wait $p 2>/dev/null || true; done
  local sum=0 busy
  for f in "$d"/s*.log; do local g; g=$(grep -oE 'goodput=[0-9.]+' "$f"|cut -d= -f2); [ -n "${g:-}" ] && sum=$(awk -v a=$sum -v x=$g 'BEGIN{print a+x}'); done
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  printf "  %-14s b=%-3s #%-2s got=%-7s busy=%s%%\n" "$lbl" "$tot" "$i" "$sum" "${busy:-NA}" | tee -a "$LOG/summary.txt"
  echo "$lbl $tot $sum ${busy:-0}" >> "$LOG/raw.txt"
}

tcp1() {  # tcp1 <label> <i>
  local lbl="$1" i="$2"
  local d="$LOG/${lbl}_$i"; mkdir -p "$d"
  ssh sslab4 "taskset -c 1 $IPERF -s -B $SRV_IP -1" > "$d/srv.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mp.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF -c $SRV_IP -l 1M -t $DUR" > "$d/cli.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true
  local rx busy
  rx=$(grep receiver "$d/cli.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  [ -z "${rx:-}" ] && return
  printf "  %-14s      #%-2s got=%-7s busy=%s%%\n" "$lbl" "$i" "$rx" "${busy:-NA}" | tee -a "$LOG/summary.txt"
  echo "$lbl 0 $rx ${busy:-0}" >> "$LOG/raw.txt"
}

echo "===== A. 단일 흐름: 레버를 하나씩 쌓는다 =====" | tee -a "$LOG/summary.txt"

setring 1024
sc "net.core.rmem_default=212992 net.core.rmem_max=212992 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0"
for i in $(seq 1 $N); do for b in 40 48 56; do udp1 "A0_stock" "$b" "$i"; done; done

sc "net.core.rmem_default=1048576 net.core.rmem_max=1048576"
for i in $(seq 1 $N); do for b in 40 48 56; do udp1 "A1_rmem1M" "$b" "$i"; done; done

setring 128
for i in $(seq 1 $N); do for b in 40 48 56; do udp1 "A2_ring128" "$b" "$i"; done; done

sc "net.ipv4.udp_rx_shed=1"
for i in $(seq 1 $N); do for b in 40 48 56; do udp1 "A3_shed" "$b" "$i"; done; done

echo "" | tee -a "$LOG/summary.txt"
echo "===== B. 8 소켓 48G: 전역 예산 =====" | tee -a "$LOG/summary.txt"
sc "net.core.rmem_default=212992 net.core.rmem_max=536870912 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0"
for i in $(seq 1 $N); do udp8 "B0_stock208K" 48 "$i"; done
sc "net.core.rmem_default=1048576 net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 net.ipv4.udp_rmem_cache_pct=0"
for i in $(seq 1 $N); do udp8 "B1_at_nobudget" 48 "$i"; done
sc "net.ipv4.udp_rmem_cache_pct=50"
for i in $(seq 1 $N); do udp8 "B2_at_budget" 48 "$i"; done

echo "" | tee -a "$LOG/summary.txt"
echo "===== C. 과부하 72G: shed =====" | tee -a "$LOG/summary.txt"
sc "net.core.rmem_default=1048576 net.core.rmem_max=1048576 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0"
for i in $(seq 1 $N); do udp1 "C0_noshed" 72 "$i"; done
sc "net.ipv4.udp_rx_shed=1"
for i in $(seq 1 $N); do udp1 "C1_shed" 72 "$i"; done

echo "" | tee -a "$LOG/summary.txt"
echo "===== D. TCP 기준선 (기본 tcp_rmem) =====" | tee -a "$LOG/summary.txt"
sc "net.ipv4.tcp_rmem='4096 131072 6291456' net.core.rmem_max=536870912 net.ipv4.udp_rx_shed=0"
for i in $(seq 1 $N); do tcp1 "D_tcp" "$i"; done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; g[k]+=$3; b[k]+=$4; n[k]++}
 END{for(k in n){split(k,a," "); printf "%-14s %-4s  got=%6.2f  busy=%3.0f%%  (n=%d)\n",
   a[1], (a[2]=="0"?"-":a[2]"G"), g[k]/n[k], b[k]/n[k], n[k]}}' "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"

sc "net.core.rmem_default=212992 net.core.rmem_max=212992 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 net.ipv4.udp_rmem_cache_pct=50"
ssh sslab4 "pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
