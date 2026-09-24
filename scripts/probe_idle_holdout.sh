#!/bin/bash
# probe_idle_holdout.sh — 침묵한 소켓들이 예산을 고갈시켜 신규 소켓을 굶기는가
#
# probe_idle_grant.sh 로 "침묵하면 축소가 안 일어난다"는 것은 확인했다(축소는
# 패킷 도착 시에만 평가되므로 도착이 없으면 평가도 없다). 하지만 그 실험은
# 소켓이 둘뿐이라 예산(9MB = L3 18MB 의 50%)이 남아 손해가 드러나지 않았다.
#
# 여기서는 예산을 **고갈**시킨 뒤 신규 소켓 하나를 56G 로 받는다. 56G 는
# 버퍼 크기가 처리량을 가르는 지점이다 (실측: 1M -> 32, 2~4M -> 55.5).
#
#   phase1: H1..H3 을 **순차로** 각각 48G 로 키운다 (각 4M -> grant 3M x 3 = 9M = 예산 전부)
#   phase2: H* 전원 침묵, 소켓은 열린 채로 유지  (회수 경로 없음)
#   phase3: D 가 홀로 56G - 클 수 있는가
#
#   대조군 free: phase2 에서 H* 소켓을 **닫는다**. 닫으면 udp_destruct_common()
#                이 grant 를 반납하므로 D 가 자랄 수 있어야 한다.
#
# hold 가 free 보다 나쁘면 "도착과 무관한 회수 경로"가 필요하다는 뜻이다.
set -u
SRV_IP=192.168.11.238; PH=5310; PD=5320; N="${1:-3}"; QUIET=12
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/idlehold_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r; dmesg | grep -o 'receive budget sized.*' | tail -1" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

one() {  # one <label> <close_holders 0|1> <i>
  local lbl="$1" close="$2" i="$3"
  local d="$LOG/${lbl}_$i"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
      net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=4194304 \
      net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=0 >/dev/null"
  # holder 소켓 수명: close=1 이면 phase2 전에 끝나고, 0 이면 끝까지 산다
  local hdur; [ "$close" = 1 ] && hdur=8 || hdur=$(( 24 + QUIET + 14 ))
  # holder 를 **순차로** 키운다. 셋을 동시에 16G 씩 먹이면 소켓별 점유가
  # 성장 조건(rmem > rcvbuf/2)에 못 닿아 아무도 안 자란다 - 성장은 총량이
  # 아니라 소켓별 점유가 정한다. 하나씩 48G 를 먹이면 확실히 4M 까지 간다.
  local pids=""
  for h in 0 1 2; do
    ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $((PH+h)) 2 $hdur" \
        > "$d/h$h.log" 2>&1 &
    pids="$pids $!"
    sleep 1
    ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $((PH+h)) 8972 7 6 48" >/dev/null 2>&1
  done
  local held; held=$(ssh sslab4 "ss -uam state unconnected 2>/dev/null | grep -oE 'rb[0-9]+' | sort | uniq -c | tr '\n' ' '")
  sleep "$QUIET"
  # --- phase3: D 홀로 56G ---
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $PD 2 12" > "$d/d.log" 2>&1 &
  local SD=$!
  sleep 1
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $PD 8972 7 10 56" > "$d/dtx.log" 2>&1
  local dbuf; dbuf=$(ssh sslab4 "ss -uam state unconnected sport = :$PD 2>/dev/null | grep -oE 'rb[0-9]+' | head -1")
  wait $SD $pids 2>/dev/null || true
  local dg off ok
  dg=$(grep -oE 'goodput=[0-9.]+' "$d/d.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/dtx.log" | cut -d= -f2)
  ok=$(awk -v o="${off:-0}" 'BEGIN{print (o >= 0.97*56) ? 1 : 0}')
  printf "  %-8s #%-2s  holder버퍼=[%s]  D버퍼=%-10s D=%s%s\n" \
     "$lbl" "$i" "$held" "${dbuf:-NA}" "${dg:-NA}" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=${off}, 제외")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$lbl ${dg:-0}" >> "$LOG/raw.txt"
}

for i in $(seq 1 $N); do
  one "hold" 0 "$i"     # holder 살아있음: grant 를 쥔 채 침묵
  one "free" 1 "$i"     # holder 닫힘: close 가 grant 를 반납
done

echo "" | tee -a "$LOG/summary.txt"
awk '{g[$1]+=$2; n[$1]++} END{for(k in n) printf "%-8s D처리량=%6.2f Gbps (n=%d)\n", k, g[k]/n[k], n[k]}' \
  "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.core.rmem_default=212992 net.core.rmem_max=212992 net.ipv4.udp_rmem_autotune_max=1048576 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
