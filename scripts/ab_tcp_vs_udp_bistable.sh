#!/bin/bash
# ab_tcp_vs_udp_bistable.sh — 실험 2: 논지의 직접 검증
#
# 논지: TCP 의 receive window 는 의도치 않은 워킹셋 조절기다.
#   consumer 감속 -> rwnd 축소 -> sender 후퇴 -> 큐 배수 -> 워킹셋 감소 -> 캐시 회복
#   = 음의 피드백.  UDP 에는 이 루프가 없어 양의 피드백(미스->감속->큐심화->더 미스)이
#   붕괴 상태를 흡수 상태로 만든다.
#
# 검증 방법: **워킹셋(수신 버퍼)을 동일하게 맞추고** 같은 부하에서 반복 시행해
#   결과 분포가 단봉(TCP)인지 이봉(UDP)인지 본다.
#   - UDP: net.core.rmem_default = B   (static)
#   - TCP: net.ipv4.tcp_rmem "4096 B B" (max=B 로 고정, autotune 상한을 같게)
#
# 판정:
#   TCP 단봉 + UDP 이봉  -> 논지 성립. 차이는 피드백 유무에서 온다.
#   둘 다 이봉           -> 논지 붕괴. bistability 는 UDP 고유가 아니다.
#   둘 다 단봉           -> bistability 자체가 설정 산물(ring 등)이었다.
#
# 주의: TCP 는 rate 를 못 정하므로 UDP 도 같은 "as fast as possible" 로 맞출 수 없다.
#   그래서 UDP 는 붕괴가 관측되던 46G 고정으로, TCP 는 무제한으로 돌리고
#   **각각의 시행간 분산/이봉성**을 본다 (절대값 비교가 목적이 아니다).
set -u
N="${1:-10}"; DUR="${2:-15}"; BUF="${3:-6291456}"   # 기본 6MB (TCP 기본 max 와 동일)
UDP_RATE="${4:-46}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/bistable_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
ssh sslab4 "uname -r; ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \"ring=\"\$2; exit}'" | tee "$LOG/verify.log"
echo "buffer=$BUF bytes, N=$N, dur=${DUR}s, udp_rate=${UDP_RATE}G" | tee -a "$LOG/verify.log"
: > "$LOG/raw.txt"

trial() {  # trial <proto> <i>
  local proto="$1"; local i="$2"
  local d="$LOG/${proto}_$i"; mkdir -p "$d"
  if [ "$proto" = udp ]; then
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=$BUF net.core.rmem_max=$BUF >/dev/null"
  else
    ssh sslab4 "sudo sysctl -w net.ipv4.tcp_rmem='4096 $BUF $BUF' net.core.rmem_max=$BUF >/dev/null"
  fi
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  if [ "$proto" = udp ]; then
    ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${UDP_RATE}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  else
    ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -l 1M -t $DUR" > "$d/client.log" 2>&1 || true
  fi
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true

  local rx busy
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  echo "$proto $i ${rx:-NA} ${busy:-NA}" >> "$LOG/raw.txt"
  printf "%-4s %2s | rx=%-6s busy=%-4s\n" "$proto" "$i" "${rx:-NA}" "${busy:-NA}%" | tee -a "$LOG/summary.txt"
}

for p in tcp udp; do
  echo "===== $p (N=$N) =====" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 $N); do trial "$p" "$i"; done
  # 분포 요약: 평균/표준편차/최소/최대/범위비. 이봉이면 표준편차와 범위비가 크게 나온다.
  awk -v p="$p" '$1==p && $3!="NA" {v[n++]=$3; s+=$3}
    END{ if(!n){print "no data"; exit}
         m=s/n; for(i=0;i<n;i++){d=v[i]-m; ss+=d*d}
         sd=sqrt(ss/n); mn=v[0]; mx=v[0]
         for(i=0;i<n;i++){ if(v[i]<mn)mn=v[i]; if(v[i]>mx)mx=v[i] }
         printf "  %s: mean=%.1f sd=%.2f (cv=%.1f%%) min=%.1f max=%.1f spread=%.1f\n",
                p, m, sd, 100*sd/m, mn, mx, mx-mn }' "$LOG/raw.txt" | tee -a "$LOG/summary.txt"
done

echo "--- 정렬된 값 (이봉 여부 육안 확인) ---" | tee -a "$LOG/summary.txt"
for p in tcp udp; do
  printf "%-4s: " "$p" | tee -a "$LOG/summary.txt"
  awk -v p="$p" '$1==p && $3!="NA" {printf "%s ", $3}' "$LOG/raw.txt" | tr ' ' '\n' | sort -n | tr '\n' ' ' | tee -a "$LOG/summary.txt"
  echo "" | tee -a "$LOG/summary.txt"
done

ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 net.ipv4.tcp_rmem='4096 131072 6291456' >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
