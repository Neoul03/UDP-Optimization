#!/bin/bash
# sweep_mtu1500_tuning.sh — MTU 1500에서 튜닝 레버를 다시 찾는다
#   Phase A: 정적 rcvbuf 스윕 (캐시 최적점이 9000과 같은 1.5MB인가?)
#   Phase B: app GRO on/off CPU 비교 (1500에서 GRO 레버가 더 큰가?)
#   Phase C: shed A/B (예측: 1500에서 더 효과적)
#
# 전제 (스크립트 밖에서 이미 적용):
#   양쪽 MTU 1500 / governor performance
#   sslab4: combined 1, msi_irq -> core1, adaptive-rx off, rmem_max=512M,
#           udp_rmem_autotune=0 udp_early_drop=0 udp_rx_shed=0
set -u
DUR="${1:-15}"; REPS="${2:-2}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/mtu1500_tune_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 1500 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
ssh sslab4 "uname -r; sysctl -n net.core.rmem_max net.ipv4.udp_rx_shed" | tee "$LOG/verify.log"
: > "$LOG/raw.txt"

# one <tag> <rmem_bytes> <shed 0|1> <gro 0|1> <rate> <rep>
one() {
  local tag="$1"; local bytes="$2"; local shed="$3"; local gro="$4"; local b="$5"; local rep="$6"
  local try=0 d rx tx loss busy soft
  while : ; do
    d="$LOG/${tag}_b${b}_r${rep}$([ $try -gt 0 ] && echo _retry$try)"; mkdir -p "$d"
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes net.ipv4.udp_rx_shed=$shed >/dev/null"
    ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
    local SP=$!
    sleep 2
    ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
    local MP=$!
    ssh sslab3 "IPERF3_UDP_GRO=$gro taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${b}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
    ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
    wait $SP $MP 2>/dev/null || true

    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender   "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    soft=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){s+=$9;m++}}  END {if(m)printf "%.0f",s/m}'    "$d/mpstat.log")
    # sender flake 재시도 (tx가 offered의 97% 미만)
    if [ -n "$tx" ] && awk -v t="$tx" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then
      try=$((try+1)); [ $try -le 2 ] && { echo "  (flake tx=$tx, retry $try)" >> "$LOG/run.log"; continue; }
    fi
    break
  done
  printf "%-22s b=%-3s r%s | rx=%-6s loss=%-7s busy=%-4s soft=%-4s tx=%-6s\n" \
    "$tag" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "${soft:-NA}%" "${tx:-NA}" | tee -a "$LOG/summary.txt"
  echo "$tag $b $rep rx=${rx:-NA} loss=${loss:-NA} busy=${busy:-NA} soft=${soft:-NA}" >> "$LOG/raw.txt"
}

CAPS="208K:212992 512K:524288 1M:1048576 1M5:1572864 2M:2097152 3M:3145728 4M:4194304 8M:8388608"

echo "===== Phase A: static rcvbuf sweep @ MTU1500 (shed off, GRO on) =====" | tee -a "$LOG/summary.txt"
for rep in $(seq 1 $REPS); do
  echo "--- rep $rep ---" | tee -a "$LOG/summary.txt"
  for b in 28 32; do
    for c in $CAPS; do one "A_${c%%:*}" "${c##*:}" 0 1 "$b" "$rep"; done
    echo "" | tee -a "$LOG/summary.txt"
  done
done

echo "===== Phase B: app GRO on/off @ 25G (CPU 레버 크기) =====" | tee -a "$LOG/summary.txt"
for rep in $(seq 1 $REPS); do
  one "B_gro_on"  1572864 0 1 25 "$rep"
  one "B_gro_off" 1572864 0 0 25 "$rep"
done

echo "===== Phase C: shed A/B @ 32G, 40G =====" | tee -a "$LOG/summary.txt"
for rep in $(seq 1 $REPS); do
  for b in 32 40; do
    one "C_shed_off" 1572864 0 1 "$b" "$rep"
    one "C_shed_on"  1572864 1 1 "$b" "$rep"
  done
done

ssh sslab4 "sudo sysctl -w net.core.rmem_default=1572864 net.ipv4.udp_rx_shed=0 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
