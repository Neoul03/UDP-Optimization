#!/bin/bash
# probe_l2_hypothesis.sh — "수신 버퍼 최적점을 정하는 것은 L3 가 아니라 코어 전용 L2 이다"
#
# sslab4 캐시 계층 (a): L1d 48K / L2 1280K(코어 전용) / L3 18432K(cpu0-11 공유)
#   -> 실측 최적점 1.5MB(truesize) ~= 실페이로드 1.0-1.2MB ~= L2 1.25MB
#
# 가설 H-L2: producer(NAPI softirq)와 consumer(recvmsg copyout)가 같은 코어에
#   있으므로 큐 워킹셋이 private L2 에 들어가면 handoff 가 L2 히트로 끝난다.
#
# 결정적 검증: producer/consumer 를 분리해 "공유되는 최상위 캐시 레벨"을 바꾼다.
#   same    : IRQ cpu1, consumer cpu1   -> L2 공유      (최적점 ~L2 크기, 뾰족)
#   l2split : IRQ cpu1, consumer cpu3   -> L3 만 공유   (최적점 L3 규모로 이동/평탄)
#   l3split : IRQ cpu1, consumer cpu13  -> 공유 없음    (최적점 소멸, 전반 악화)
# split arm 은 코어가 2개라 절대 처리량은 당연히 오른다. 관심은 **곡선의 모양과
# 최고점 위치**이지 절대값이 아니다.
#
# 전제 (스크립트 밖에서 적용): MTU 9000 양쪽, governor performance,
#   sslab4 combined 1 + 전 msi_irq -> cpu1, adaptive-rx off, rmem_max 512M,
#   udp_rmem_autotune=0 udp_early_drop=0 udp_rx_shed=0
set -u
DUR="${1:-15}"; REPS="${2:-2}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/l2hyp_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m (expected 9000)"; exit 1; }
done
ssh sslab4 "uname -r; cat /sys/devices/system/cpu/cpu1/cache/index2/size /sys/devices/system/cpu/cpu1/cache/index3/size" | tee "$LOG/verify.log"
: > "$LOG/raw.txt"

# one <arm> <consumer_cpu> <capname> <bytes> <rate> <rep>
one() {
  local arm="$1"; local ccpu="$2"; local cap="$3"; local bytes="$4"; local b="$5"; local rep="$6"
  local try=0 d rx tx loss busy
  while : ; do
    d="$LOG/${arm}_${cap}_b${b}_r${rep}$([ $try -gt 0 ] && echo _retry$try)"; mkdir -p "$d"
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes >/dev/null"
    local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
    ssh sslab4 "taskset -c $ccpu $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
    local SP=$!
    sleep 2
    # IRQ 코어(cpu1)와 consumer 코어를 각각 관측
    ssh sslab4 "mpstat -P 1,$ccpu 1 $DUR" > "$d/mpstat.log" 2>&1 &
    local MP=$!
    ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
    ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
    wait $SP $MP 2>/dev/null || true

    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender   "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    busy=$(awk -v c=1 '$3==c && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    local cbusy
    cbusy=$(awk -v c="$ccpu" '$3==c && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    if [ "$b" != "0" ] && [ -n "$tx" ] && awk -v t="$tx" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then
      try=$((try+1)); [ $try -le 2 ] && { echo "  (flake tx=$tx retry $try)" >> "$LOG/run.log"; continue; }
    fi
    printf "%-8s %-5s b=%-3s r%s | rx=%-6s loss=%-7s irq_cpu1=%-4s cons_cpu%-2s=%-4s\n" \
      "$arm" "$cap" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "$ccpu" "${cbusy:-NA}%" \
      | tee -a "$LOG/summary.txt"
    echo "$arm $cap $b $rep ${rx:-NA} ${loss:-NA} ${busy:-NA} ${cbusy:-NA}" >> "$LOG/raw.txt"
    break
  done
}

# L2=1.25MB 주변을 촘촘히, L3=18MB 까지 넓게
CAPS="512K:524288 768K:786432 1M:1048576 1M25:1310720 1M5:1572864 2M:2097152 \
3M:3145728 4M:4194304 6M:6291456 8M:8388608 12M:12582912 18M:18874368"

echo "===== Phase 1: same-core (baseline), blast + 46G =====" | tee -a "$LOG/summary.txt"
for rep in $(seq 1 $REPS); do
  for b in 0 46; do
    for c in $CAPS; do one "same" 1 "${c%%:*}" "${c##*:}" "$b" "$rep"; done
    echo "" | tee -a "$LOG/summary.txt"
  done
done

echo "===== Phase 2: producer/consumer 분리 (진단용 대조군), blast =====" | tee -a "$LOG/summary.txt"
for rep in $(seq 1 $REPS); do
  for c in $CAPS; do one "l2split" 3  "${c%%:*}" "${c##*:}" 0 "$rep"; done
  echo "" | tee -a "$LOG/summary.txt"
  for c in $CAPS; do one "l3split" 13 "${c%%:*}" "${c##*:}" 0 "$rep"; done
  echo "" | tee -a "$LOG/summary.txt"
done

ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
