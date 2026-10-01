#!/bin/bash
# sweep_static_mtu9000.sh — 정적 sk_rcvbuf 를 x 축에 놓고 처리량을 잰다.
#
# 이 그림이 논문에서 제일 중요한 한 장이다: **양쪽 절벽**을 한 장에 보인다.
#   왼쪽  버퍼가 NAPI 배치보다 작아 담을 데가 없어 폐기       (P1)
#   오른쪽 ring + sk_rcvbuf 가 L3 를 넘어 copyout 이 DRAM 히트 (P3)
# 어떤 정적 값도 두 절벽 사이의 좁은 골을 조건 무관하게 맞출 수 없다는 근거.
#
# ★ 과거 스윕을 전부 폐기하고 다시 재는 이유:
#   - static_rcvbuf_20260921: 스크립트가 udp_rx_shed=1 로 돌았다. 버퍼가 작으면
#     shed 창이 상시 활성이라 **왼쪽 절벽을 shed 가 만들었다**. "역U자 최적점
#     1.5MB" 주장이 여기서 나왔고 철회됐다.
#   - l2hyp_20260922 / rcvbuf_ring256: iperf3 -u -b 로 쟀다. -b 0 은 livelock,
#     -b N 은 clock_nanosleep 페이싱 양자화로 가짜 손실을 만든다 (규칙 7).
#   - 셋 다 커널이 6.18.53-udpopt20 이전이다.
#
# ★ 버퍼 스윕이 무효가 되지 않게 세 가지를 같이 건다 (세 번 당한 함정):
#   UDP_SINK_NO_RCVBUF=1   sink 가 SO_RCVBUF 64MB 를 요청하지 않게
#   udp_rmem[1] = SZ       udp_init_sock() 이 여기서 sk_rcvbuf 를 가져간다
#   rmem_max   = SZ        이게 크면 뭘 해도 전부 그 값이 된다
#   그리고 매 시행 ss -uam 의 rb 를 찍어 **실제로 걸렸는지 로그에 남긴다**.
#
# 제공률은 세 점을 쓴다. 한 점에서 일반화하지 말 것 (규칙 2) —
# 레버의 효과는 동작점에 따라 부호까지 바뀐다.
set -u
N="${1:-5}"; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/staticbuf_${TS}; mkdir -p "$LOG"
SIZES="212992 262144 393216 524288 786432 1048576 1572864 2097152 3145728 4194304 6291456 8388608 12582912 18874368"
RATES="40 56 88"

TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "sudo ethtool -G $IF rx 128 >/dev/null 2>&1"; sleep 4
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1"; sleep 2
GOV=$(ssh sslab4 "cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor")
[ "$GOV" = performance ] || { echo "FATAL governor=$GOV"; exit 1; }
CH=$(ssh sslab4 "ethtool -l $IF | awk '/Current hardware/{f=1} f&&/^Combined:/{print \$2; exit}'")
[ "$CH" = 1 ] || { echo "FATAL combined=$CH"; exit 1; }
# MTU 는 양쪽에서 assert. 리부팅하면 1500 으로 리셋된다.
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"; sleep 3
for h in sslab4 sslab3; do
  m=$(ssh $h "ip link show $IF | grep -o 'mtu [0-9]*' | awk '{print \$2}'")
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
# 우리 기능은 전부 끈다 — 순수 정적 버퍼만 본다
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null"
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'; ethtool -c $IF | grep -i adaptive; sysctl -n net.ipv4.udp_rmem_autotune net.ipv4.udp_rmem_cache_pct net.ipv4.udp_rx_shed | tr '\n' ' '; echo '(autotune cache_pct shed)'" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

human() { awk -v b="$1" 'BEGIN{ if (b>=1048576) printf "%gM", b/1048576; else printf "%gK", b/1024 }'; }

one() {  # one <size_bytes> <rate> <i>
  local sz="$1"
  local rate="$2"
  local i="$3"
  local d="$LOG/b${sz}_r${rate}_$i"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 $sz $sz' net.core.rmem_max=$sz >/dev/null"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 12" > "$d/sink.log" 2>&1 &
  local SK=$!
  sleep 1
  # 소켓이 실제로 그 버퍼를 받았는지 확인한다. 무효 스윕을 세 번 돌린 적이 있다.
  local rb; rb=$(ssh sslab4 "ss -uam 2>/dev/null | grep -A1 ':$P ' | grep -oE 'rb[0-9]+' | head -1")
  ssh sslab3 "taskset -c 1 timeout 16 /home/chanseo/udp_blast $SRV_IP $P 8972 7 10 $rate" > "$d/tx.log" 2>&1 &
  ssh sslab4 "mpstat -P 1 1 9" > "$d/mp.log" 2>&1
  wait $SK 2>/dev/null || true

  local got; got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  local tx;  tx=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  local ok; ok=$(awk -v o="${tx:-0}" -v r="$rate" 'BEGIN{print (o >= 0.97*r) ? 1 : 0}')
  printf "  %-6s rate=%-3s #%-2s got=%-7s tx=%-7s busy=%-4s %s%s\n" \
     "$(human $sz)" "$rate" "$i" "${got:-NA}" "${tx:-NA}" "${busy:-NA}%" "${rb:-rb?}" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$sz $rate ${got:-0} ${tx:-0} ${busy:-0} ${rb:-rb0}" >> "$LOG/raw.txt"
}

for rate in $RATES; do
  echo "===== 제공 ${rate}G =====" | tee -a "$LOG/summary.txt"
  for sz in $SIZES; do
    for i in $(seq 1 $N); do one "$sz" "$rate" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 (평균±sd) ===========" | tee -a "$LOG/summary.txt"
awk '{k=$2" "$1; g[k]+=$3; gg[k]+=$3*$3; t[k]+=$4; b[k]+=$5; rb[k]=$6; n[k]++}
 END{for(k in n){split(k,x," "); mu=g[k]/n[k]; sd=sqrt(gg[k]/n[k]-mu*mu);
   printf "rate %-3s  buf %-9s  got=%6.2f +-%5.2f  tx=%6.2f  busy=%3.0f%%  %s (n=%d)\n",
   x[1],x[2],mu,sd,t[k]/n[k],b[k]/n[k],rb[k],n[k]}}' "$LOG/raw.txt" \
 | sort -k2,2n -k4,4n | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 >/dev/null; pgrep -a 'udp_sink|[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
