#!/bin/bash
# probe_dim_trajectory.sh — DIM 이 실제로 무엇을 고르는지, 붕괴와 어떻게 대응되는지
#
# rx-usecs 를 **정적으로** 4~256 스윕해도 붕괴가 재현되지 않았다 (전 구간 47.98,
# sd 0.00). 그러므로 원인은 "DIM 이 고른 usec 값"이 아니다. 남은 후보:
#   (a) rx-frames. 정적 스윕은 frames=32 로 고정했는데 DIM 의 EQE 프로파일은
#       pkts = NET_DIM_DEFAULT_RX_CQ_PKTS_FROM_EQE = 256 을 쓴다 (dim.h:17).
#       즉 정적 스윕은 DIM 이 쓰는 지점을 한 번도 안 밟았다.
#   (b) 값이 아니라 **바꾸는 행위**. 프로파일 전환마다 CQ moderation 을 다시
#       프로그램해야 하고, 진동하면 그 비용을 계속 낸다.
#
# 이 스크립트는 DIM 을 켠 채 48G 를 흘리며 rx-usecs/rx-frames 를 주기적으로 읽어
# **궤적**을 남긴다. 정착하면 (a), 계속 흔들리면 (b) 다.
# 좋은 시행과 나쁜 시행이 섞여 나오므로 goodput 과 함께 기록해 대응시킨다.
set -u
N="${1:-6}"; RATE="${2:-48}"; DUR=12; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/dimtraj_${TS}; mkdir -p "$LOG"
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1"; sleep 2
ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null"
: > "$LOG/raw.txt"

for i in $(seq 1 $N); do
  d="$LOG/run$i"; mkdir -p "$d"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 $DUR" > "$d/sink.log" 2>&1 &
  SP=$!
  sleep 1
  # 원격에서 한 번에 샘플링한다. ssh 를 반복하면 그 오버헤드가 측정을 바꾼다.
  ssh sslab4 "for k in \$(seq 1 40); do ethtool -c $IF | awk '/^rx-usecs:/{u=\$2} /^rx-frames:/{f=\$2} END{print u, f}'; sleep 0.25; done" \
      > "$d/traj.log" 2>&1 &
  TR=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $((DUR-2)) $RATE" > "$d/tx.log" 2>&1
  wait $SP $TR 2>/dev/null || true
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  # 궤적 요약: 서로 다른 (usec,frames) 조합과 전환 횟수
  summ=$(awk '{k=$1"/"$2; c[k]++; if(k!=prev){sw++; prev=k}} END{
      n=0; s=""; for(k in c){s=s sprintf("%s x%d  ", k, c[k]); n++}
      printf "전환=%d  고유=%d  %s", sw-1, n, s}' "$d/traj.log")
  ok=$(awk -v o="${off:-0}" -v r="$RATE" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  #%-2s got=%-7s %s%s\n" "$i" "${got:-NA}" "$summ" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE tx=${off}")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$i ${got:-0}" >> "$LOG/raw.txt"
done

ssh sslab4 "sudo ethtool -C $IF adaptive-rx off >/dev/null 2>&1; sudo sysctl -w net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
