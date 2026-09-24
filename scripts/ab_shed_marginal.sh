#!/bin/bash
# ab_shed_marginal.sh — autotune 이 이미 있을 때 shed 가 얼마를 더 주는가
#
# shed 의 가치를 보인 실험들은 전부 **autotune 없이** 돌았다 (rmem 1M 고정):
#   72G 과부하    55.72 -> 61.83 (+11%)
#   TCP+UDP 동시  TCP 13.8 -> 22.1 (+60%)
#   GRO off 56G   27.85 -> 47.94 (+72%)
# 이 숫자들은 "shed vs 아무것도 없음"이지 **한계 기여**가 아니다. autotune 이
# 버퍼를 늘려 같은 붕괴를 이미 막고 있다면 shed 가 더 줄 것이 없을 수도 있다.
#
# v15 에서 천장 근처(56G)만 보면 DIM on 에서 +0.4% 로 무시할 만하다. 그러나
# 레버의 효과는 동작점에 따라 부호까지 바뀌므로(측정 원칙 2) **천장 너머까지**
# 사다리를 늘려야 판단할 수 있다. 여기가 shed 가 존재하는 이유인 구간이다.
#
# arms: auto / auto+shed / 정적 1M (참조) / 정적 1M+shed (옛 주장 재현용)
#
#   usage: ab_shed_marginal.sh [reps]
set -u
N="${1:-5}"; DUR=12; IF=ens81f0np0
SRV_IP=192.168.11.238; P=5301
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/shedmarg_${TS}; mkdir -p "$LOG"
for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }
ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

setarm() {
  case "$1" in
    s1M)      ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
                  net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    s1M_shed) ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=1048576 \
                  net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
    auto)     ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
                  net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
                  net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    auto_shed)ssh sslab4 "sudo sysctl -w net.core.rmem_default=1048576 net.core.rmem_max=536870912 \
                  net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_autotune_max=67108864 \
                  net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
  esac
}

one() {  # one <dim> <arm> <rate> <i>
  local dim="$1" arm="$2" b="$3" i="$4"
  local d="$LOG/${dim}_${arm}_b${b}_$i"; mkdir -p "$d"
  ssh sslab4 "UDP_SINK_NO_RCVBUF=1 taskset -c 1 /home/chanseo/udp_sink $SRV_IP $P 2 $DUR" > "$d/sink.log" 2>&1 &
  local SP=$!
  sleep 1
  ssh sslab4 "mpstat -P 1 1 $((DUR-3))" > "$d/mp.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 /home/chanseo/udp_blast $SRV_IP $P 8972 7 $((DUR-2)) $b" > "$d/tx.log" 2>&1
  wait $SP $MP 2>/dev/null || true
  local got off busy rb ok
  got=$(grep -oE 'goodput=[0-9.]+' "$d/sink.log" | cut -d= -f2)
  off=$(grep -oE 'offered=[0-9.]+' "$d/tx.log" | cut -d= -f2)
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  # 제공률이 목표에 못 미치면 sender flake 다. 과부하 구간에서는 sender 가
  # 못 따라가는 것과 receiver 붕괴를 반드시 구분해야 한다.
  ok=$(awk -v o="${off:-0}" -v r="$b" 'BEGIN{print (o >= 0.95*r) ? 1 : 0}')
  printf "  dim=%-3s %-9s b=%-3s #%-2s got=%-7s busy=%-4s tx=%s%s\n" \
     "$dim" "$arm" "$b" "$i" "${got:-NA}" "${busy:-NA}%" "${off:-NA}" \
     "$([ "$ok" = 1 ] || echo "  <-- FLAKE")" | tee -a "$LOG/summary.txt"
  [ "$ok" = 1 ] && echo "$dim $arm $b ${got:-0} ${busy:-0}" >> "$LOG/raw.txt"
}

for dim in on off; do
  ssh sslab4 "sudo ethtool -C $IF adaptive-rx $dim >/dev/null 2>&1"; sleep 2
  for arm in auto auto_shed s1M s1M_shed; do
    setarm "$arm"
    for i in $(seq 1 $N); do
      for b in 48 56 64 72 80; do one "$dim" "$arm" "$b" "$i"; done
    done
  done
done

echo "" | tee -a "$LOG/summary.txt"
awk '{k=sprintf("dim=%-3s %-9s %3sG", $1, $2, $3); g[k]+=$4; b[k]+=$5; n[k]++}
 END{for(k in n) printf "%s  got=%6.2f  busy=%3.0f%%  (n=%d)\n", k, g[k]/n[k], b[k]/n[k], n[k]}' \
 "$LOG/raw.txt" | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1; sudo sysctl -w net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rx_shed=0 net.core.rmem_default=212992 net.core.rmem_max=212992 >/dev/null; pgrep -a udp_sink || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
