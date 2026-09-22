#!/bin/bash
# probe_cache_counters.sh — 캐시 가설을 PMU 로 직접 검증한다 (증거 등급 b -> a)
#
# 지금까지의 캐시 주장은 전부 간접 증거였다: 드롭 위치(rx_out_of_buffer=0),
#   CPU 사용률, 처리량, 그리고 producer/consumer 를 분리했을 때의 기울기 차이.
#   LLC/L2 미스를 실제로 잰 적이 없다.
#
# 설계의 핵심: **천장 아래(44G)에서 잰다.**
#   44G 는 모든 버퍼 크기에서 무손실이므로(측정됨: 0.02%) 처리량이 상수다.
#   따라서 미스율 차이는 순수하게 캐시 거동의 차이이고, 손실률 변화라는
#   교란 요인이 없다. 천장 위에서 재면 "적게 받아서 미스가 적다" 와 구분 불가.
#
# 예측 (캐시 가설이 옳다면):
#   rcvbuf ↑  -> L2 미스율 ↑, L3 미스 ↑, DRAM 읽기 ↑
#   ring   ↑  -> 같은 방향 (descriptor page 가 LLC 를 선점)
# 반증되면: 미스율이 버퍼/ring 과 무관 -> 캐시 해석 전면 재검토
#
#   usage: probe_cache_counters.sh [N] [rate]
set -u
N="${1:-3}"; RATE="${2:-44}"; DUR=12
PERF=/usr/lib/linux-tools/6.6.9/perf
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/cachecnt_${TS}; mkdir -p "$LOG"
SRV_IP=192.168.11.238; PORT=5301; IF=ens81f0np0

ssh sslab4 "uname -r" | tee "$LOG/verify.log"
echo "rate=${RATE}G N=$N" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

# 2 fixed(cycles,instructions) + 4 general -> 멀티플렉싱 없이 들어간다
EVENTS="cycles,instructions,r3f24,rff24,r04d1,r20d1"
#   r3f24 = L2_RQSTS.MISS         rff24 = L2_RQSTS.REFERENCES
#   r04d1 = MEM_LOAD_RETIRED.L3_HIT  r20d1 = MEM_LOAD_RETIRED.L3_MISS

one() {  # one <ring> <capname> <bytes> <i>
  local ring="$1"; local cap="$2"; local bytes="$3"; local i="$4"
  local d="$LOG/r${ring}_${cap}_$i"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes net.core.rmem_max=$bytes net.ipv4.udp_rx_shed=0 >/dev/null"
  ssh sslab4 "taskset -c 1 /home/chanseo/udp_sink $SRV_IP $PORT 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  # cpu1 에만 붙여 센다 (전 시스템이 아니라 우리 코어)
  ssh sslab4 "sudo $PERF stat -e $EVENTS -C 1 --timeout $(( (DUR-3)*1000 ))" > "$d/perf.txt" 2>&1 &
  local PF=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PORT 8972 7 $((DUR-2)) $RATE" > "$d/blast.log" 2>&1 || true
  wait $SP $PF 2>/dev/null || true

  local got v
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  [ -z "${got:-}" ] && { echo "  (sink 실패)" | tee -a "$LOG/summary.txt"; return; }
  get() { grep -oE "^ *[0-9,]+ +$1" "$d/perf.txt" | head -1 | awk '{gsub(/,/,"",$1); print $1}'; }
  local cyc ins l2m l2r l3h l3m
  cyc=$(get cycles); ins=$(get instructions)
  l2m=$(get r3f24); l2r=$(get rff24); l3h=$(get r04d1); l3m=$(get r20d1)
  [ -z "${l2r:-}" ] && { echo "  (perf 파싱 실패)" | tee -a "$LOG/summary.txt"; head -20 "$d/perf.txt"; return; }
  awk -v ring="$ring" -v cap="$cap" -v i="$i" -v g="$got" -v c="$cyc" -v n="$ins" \
      -v a="$l2m" -v b="$l2r" -v h="$l3h" -v m="$l3m" \
    'BEGIN{ ipc=(c>0)?n/c:0; l2=(b>0)?100*a/b:0; l3=((h+m)>0)?100*m/(h+m):0;
      printf "  ring=%-4s %-5s #%-2s got=%-7s IPC=%.2f  L2miss=%5.1f%%  L3miss=%5.1f%%  L2refs=%s\n",
        ring, cap, i, g, ipc, l2, l3, b }' | tee -a "$LOG/summary.txt"
  echo "$ring $cap ${got} ${cyc} ${ins} ${l2m} ${l2r} ${l3h} ${l3m}" >> "$LOG/raw.txt"
}

# ring 은 스크립트 밖에서 설정한다 (복합 sudo 블록이 permission classifier 에 걸림)
actual=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
echo "===== ring=$actual, offered ${RATE}G (천장 아래 = 무손실 = 처리량 상수) =====" | tee -a "$LOG/summary.txt"
for c in 256K:262144 1M:1048576 4M:4194304 16M:16777216; do
  for i in $(seq 1 $N); do one "$actual" "${c%%:*}" "${c##*:}" "$i"; done
done

echo "======= 요약 =======" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; g[k]+=$3; c[k]+=$4; n[k]+=$5; a[k]+=$6; b[k]+=$7; h[k]+=$8; m[k]+=$9; cnt[k]++}
 END{ for(k in cnt){ split(k,f," ");
   printf "ring=%-5s %-5s  got=%6.2f  IPC=%.2f  L2miss=%5.1f%%  L3miss=%5.1f%%\n",
     f[1], f[2], g[k]/cnt[k], n[k]/c[k], 100*a[k]/b[k], 100*m[k]/(h[k]+m[k]) } }' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"

ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
