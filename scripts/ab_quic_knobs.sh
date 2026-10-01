#!/bin/bash
# ab_quic_knobs.sh — QUIC 에서 ours 가 stock 보다 느린 원인을 knob 별로 가른다.
#
# 관측 (단일 연결, 3/3 재현):
#   stock  2.65 / 2.68 / 2.78 Gb/s   busy 21~22%
#   ours   2.31 / 2.36        Gb/s   busy 25%
# CPU 를 더 쓰면서 처리량이 낮다. 우리 기전은 2.5 Gb/s 에서는 놀고 있어야 하므로
# 설명이 필요하다.
#
# 가설 두 개:
#   (1) shed 가 패킷을 버리고 QUIC 의 혼잡제어가 그 손실에 반응해 속도를 줄인다.
#       UDP 벤치는 손실을 그냥 손실로 집계하지만 QUIC 은 **sender 가 물러선다**.
#       그렇다면 이건 "손실을 만드는 기전은 CC 프로토콜에 해롭다"는 일반적 결과다.
#   (2) autotune 의 도착당 원자연산이 syscall-bound 워크로드에 얹히는 순수 오버헤드.
#       quiche 는 UDP_GRO 를 안 켜므로 udp_rcv_segment() 재분할 뒤 segment 마다
#       autotune 이 돈다 - 1350B 짜리가 231k/s 다.
#
# knob 을 하나씩 켜서 가른다. RcvbufErrors 증분도 같이 본다.
set -u
N="${1:-3}"
SRV=192.168.11.120
QS='$HOME/quiche/target/release/quiche-server'
QC='$HOME/quiche/target/release/quiche-client'
CERT='$HOME/quiche/apps/src/bin/cert.crt'
KEY='$HOME/quiche/apps/src/bin/cert.key'
B=2147483648
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/quicab_${TS}; mkdir -p "$LOG"

ssh sslab4 "uname -r" | tee "$LOG/summary.txt"
: > "$LOG/raw.txt"

setcfg() {   # off / auto / shed / both
  local a=0 p=0 s=0
  case "$1" in
    auto) a=1; p=50 ;;
    shed) s=1 ;;
    both) a=1; p=50; s=1 ;;
  esac
  local mid=212992; local maxv=212992
  [ "$a" = 1 ] && maxv=67108864
  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 $mid $maxv' net.core.rmem_max=212992 \
      net.ipv4.udp_rmem_autotune=$a net.ipv4.udp_rmem_cache_pct=$p net.ipv4.udp_rx_shed=$s >/dev/null"
}

one() {  # one <cfg> <i>
  local cfg="$1"
  local i="$2"
  local d="$LOG/${cfg}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  ssh sslab3 "nohup $QS --listen 0.0.0.0:4433 --root \$HOME/quicroot --cert $CERT --key $KEY \
      --max-data 10000000000 --max-stream-data 10000000000 > ~/quic_srv.log 2>&1 &" </dev/null
  sleep 3
  ssh sslab4 "rm -rf /tmp/qk; mkdir -p /tmp/qk; nstat -n"
  ssh sslab4 "mpstat -P 1 1 20" > "$d/mp.log" 2>&1 &
  local MP=$!
  local t0; t0=$(date +%s.%N)
  ssh sslab4 "taskset -c 1 $QC --no-verify --max-data 10000000000 --max-stream-data 10000000000 \
      https://$SRV:4433/blob --dump-responses /tmp/qk" > "$d/c.log" 2>&1
  local t1; t1=$(date +%s.%N)
  local err; err=$(ssh sslab4 "nstat 2>/dev/null | awk '/UdpRcvbufErrors/{print \$2}'")
  local rb; rb=$(ssh sslab4 "cat /tmp/qk/blob 2>/dev/null | wc -c")
  wait $MP 2>/dev/null || true
  ssh sslab3 "pkill -f '[q]uiche-server' 2>/dev/null; true"
  ssh sslab4 "rm -rf /tmp/qk 2>/dev/null; true"

  local el; el=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
  local g; g=$(awk -v by="$rb" -v e="$el" 'BEGIN{ if (e>0) printf "%.2f", by*8/e/1e9; else print 0 }')
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  printf "  %-5s #%-2s got=%-7s elapsed=%-6s busy=%-5s RcvbufErrors=%s\n" \
     "$cfg" "$i" "$g" "$el" "${busy:-NA}%" "${err:-0}" | tee -a "$LOG/summary.txt"
  [ "${rb:-0}" = "$B" ] && echo "$cfg $g ${busy:-0} ${err:-0}" >> "$LOG/raw.txt" \
     || echo "  WARN 받은 바이트 $rb != $B" | tee -a "$LOG/summary.txt"
}

for i in $(seq 1 "$N"); do
  for c in off auto shed both; do one "$c" "$i"; done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 (평균±sd) ===========" | tee -a "$LOG/summary.txt"
awk '{g[$1]+=$2; gg[$1]+=$2*$2; b[$1]+=$3; e[$1]+=$4; n[$1]++}
 END{for(k in n){mu=g[k]/n[k]; printf "%-5s got=%6.2f +-%5.2f  busy=%3.0f%%  RcvbufErrors=%9.0f  (n=%d)\n",
   k,mu,sqrt(gg[k]/n[k]-mu*mu),b[k]/n[k],e[k]/n[k],n[k]}}' "$LOG/raw.txt" \
 | sort | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null"
ssh sslab3 "pgrep -a '[q]uiche-server' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
