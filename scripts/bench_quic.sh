#!/bin/bash
# bench_quic.sh — QUIC(quiche) 수신 처리량을 기존 커널 설정과 우리 것으로 비교한다.
#
# 방향: 우리 패치는 **sslab4** 에 있으므로 거기가 수신측이어야 한다.
#   sslab3 = quiche-server (파일을 보낸다)
#   sslab4 = quiche-client (받는다)  <- 우리 커널
#
# ★ 먼저 알아둘 것 (코드에서 확인, apps/src/client.rs):
#     const MAX_DATAGRAM_SIZE: usize = 1350;          // MTU 와 무관하게 1350B
#     let (len, from) = socket.recv_from(&mut buf);   // datagram 당 syscall 하나
#   quiche 의 앱 계층은 UDP_GRO 도 SO_RCVBUF 도 부르지 않는다. 즉 실제 QUIC
#   수신 경로는 우리가 최적화한 두 기전(GRO 로 합친 큰 skb, 크게 잡힌 버퍼)을
#   애초에 쓰지 않는다. 그래서 차이가 안 나올 가능성이 높고, **그 null 자체가
#   보고할 결과**다. 측정해서 확인한다.
#
# arm:
#   stock   autotune/cap/shed 전부 off  (오늘의 기본 커널 동작)
#   ours    autotune=1 cache_pct=50 shed=1
#
# 축: 동시 연결 수. QUIC 은 혼잡제어가 속도를 정하므로 "요청 속도"를 x 축에 둘 수
#   없다. 연결 하나 = UDP 소켓 하나이므로 연결 수가 곧 Sigma sk_rcvbuf 이고,
#   그게 우리 cap 이 작동하는 축이다.
set -u
N="${1:-3}"
CONNS="${2:-1 2 4 8 16}"
IF=ens81f0np0
SRV_IP=192.168.11.120          # sslab3 (sender/server)
PORT=4433
QS='$HOME/quiche/target/release/quiche-server'
QC='$HOME/quiche/target/release/quiche-client'
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/quic_${TS}; mkdir -p "$LOG"
SIZE_MB=2048                    # 받을 파일 크기

for h in sslab3 sslab4; do
  ssh $h "[ -x \$HOME/quiche/target/release/quiche-client ]" || { echo "FATAL $h quiche 없음"; exit 1; }
done
TOP=$(ssh sslab4 "ps -eo pcpu --sort=-pcpu --no-headers | head -1 | cut -d. -f1")
[ "${TOP:-0}" -lt 5 ] || { echo "FATAL receiver busy (${TOP}%)"; exit 1; }

# 단일코어 방법론 (수신측)
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "sudo ethtool -G $IF rx 128 >/dev/null 2>&1"; sleep 4
ssh sslab4 "sudo ethtool -L $IF combined 1 >/dev/null 2>&1"; sleep 3
ssh sslab4 "for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done"
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on >/dev/null 2>&1"; sleep 2
ssh sslab4 "sudo ip link set $IF mtu 9000"; ssh sslab3 "sudo ip link set $IF mtu 9000"; sleep 2
ssh sslab4 "uname -r; ethtool -g $IF | awk '/^Current/{f=1} f&&/^RX:/{print \"ring \" \$2; exit}'" | tee "$LOG/summary.txt"
echo "quiche: datagram 1350B, recv_from 1회/datagram, UDP_GRO/SO_RCVBUF 미사용" | tee -a "$LOG/summary.txt"
: > "$LOG/raw.txt"

# 서버가 내줄 파일
ssh sslab3 "mkdir -p ~/quicroot && [ -s ~/quicroot/blob ] || dd if=/dev/zero of=~/quicroot/blob bs=1M count=$SIZE_MB status=none; ls -la ~/quicroot/blob"

setcfg() {
  case "$1" in
    stock) ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
               net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null" ;;
    ours)  ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 67108864' net.core.rmem_max=212992 \
               net.ipv4.udp_rmem_autotune=1 net.ipv4.udp_rmem_cache_pct=50 net.ipv4.udp_rx_shed=1 >/dev/null" ;;
  esac
}

one() {  # one <cfg> <nconn> <i>
  local cfg="$1"
  local nc="$2"
  local i="$3"
  local d="$LOG/${cfg}_c${nc}_$i"; mkdir -p "$d"
  setcfg "$cfg"
  # 서버는 --cert/--key 기본값이 상대경로라 절대경로를 줘야 한다 (안 주면 TlsFail).
  ssh sslab3 "nohup $QS --listen 0.0.0.0:$PORT --root \$HOME/quicroot \
      --cert \$HOME/quiche/apps/src/bin/cert.crt --key \$HOME/quiche/apps/src/bin/cert.key \
      --max-data 10000000000 --max-stream-data 10000000000 > ~/quic_srv.log 2>&1 &" </dev/null
  sleep 3
  # --dump-responses 는 존재하는 디렉터리를 요구한다. 없으면 클라이언트가 즉시 죽는다.
  ssh sslab4 "for c in \$(seq 1 $nc); do rm -rf /tmp/qb\$c; mkdir -p /tmp/qb\$c; done"
  ssh sslab4 "mpstat -P 1 1 20" > "$d/mp.log" 2>&1 &
  local MP=$!
  local t0; t0=$(date +%s.%N)
  for c in $(seq 1 "$nc"); do
    ssh sslab4 "taskset -c 1 $QC --no-verify --max-data 10000000000 --max-stream-data 10000000000 \
        https://$SRV_IP:$PORT/blob --dump-responses /tmp/qb$c" > "$d/c$c.log" 2>&1 &
  done
  for j in $(jobs -p); do [ "$j" = "$MP" ] || wait "$j" 2>/dev/null; done
  local t1; t1=$(date +%s.%N)
  wait $MP 2>/dev/null || true
  ssh sslab3 "pkill -f '[q]uiche-server' 2>/dev/null; true"

  # 배달 바이트는 덤프된 파일 크기로 센다 - 앱이 실제로 받은 양이다.
  local bytes; bytes=$(ssh sslab4 "cat /tmp/qb*/blob 2>/dev/null | wc -c")
  ssh sslab4 "rm -rf /tmp/qb* 2>/dev/null; true"
  local el; el=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')
  local gbps; gbps=$(awk -v by="$bytes" -v e="$el" 'BEGIN{ if (e>0) printf "%.2f", by*8/e/1e9; else print 0 }')
  local busy; busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>2){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mp.log")
  printf "  %-5s conns=%-3s #%-2s got=%-7s bytes=%-13s elapsed=%-6s busy=%s\n" \
     "$cfg" "$nc" "$i" "${gbps:-NA}" "$bytes" "$el" "${busy:-NA}%" | tee -a "$LOG/summary.txt"
  [ "${bytes:-0}" -gt 0 ] && echo "$nc $cfg $gbps $bytes ${busy:-0}" >> "$LOG/raw.txt"
}

for nc in $CONNS; do
  echo "===== 동시 연결 $nc =====" | tee -a "$LOG/summary.txt"
  for i in $(seq 1 "$N"); do
    for c in stock ours; do one "$c" "$nc" "$i"; done
  done
done

echo "" | tee -a "$LOG/summary.txt"
echo "=========== 요약 (평균±sd) ===========" | tee -a "$LOG/summary.txt"
awk '{k=$1" "$2; g[k]+=$3; gg[k]+=$3*$3; b[k]+=$5; n[k]++}
 END{for(k in n){split(k,x," "); mu=g[k]/n[k]; sd=sqrt(gg[k]/n[k]-mu*mu);
   printf "conns %-3s %-5s  got=%6.2f +-%5.2f  busy=%3.0f%%  (n=%d)\n",
   x[1],x[2],mu,sd,b[k]/n[k],n[k]}}' "$LOG/raw.txt" | sort -k2,2n -k3,3 | tee -a "$LOG/summary.txt"
ssh sslab4 "sudo sysctl -w net.ipv4.udp_rmem='4096 212992 212992' net.core.rmem_max=212992 \
    net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_rmem_cache_pct=0 net.ipv4.udp_rx_shed=0 >/dev/null"
ssh sslab3 "pgrep -a '[q]uiche-server' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
