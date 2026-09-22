#!/bin/bash
# sweep_ring_x_rcvbuf.sh — 실험 1: RX ring 크기 × rcvbuf 2D 스윕
#
# 동기 (Sepia, OSDI'26 §2,§3.2):
#   ConnectX 는 MPWQE 당 64 pages 를 잡는다. ring=1024 + MTU 9000 이면
#   드라이버가 ring 당 64 WQE 를 초기화 -> **코어당 16MB** 의 descriptor page.
#   sslab4 의 소켓당 L3 는 18MB, 그나마 Linux 기본 할당자의 유효 LLC 는
#   conflict miss 때문에 전체의 ~46% (Sepia Fig.9) -> 약 8MB.
#   => ring 만으로 이미 유효 LLC 를 2배 초과. 페이로드는 한 바이트도 넣기 전에.
#
# 가설 (c): 지금까지 본 "rcvbuf 단조 감소" 는 곡선의 오른쪽 꼬리일 뿐이다.
#   ring 을 줄여 LLC 여유를 만들면 곡선 모양 자체가 바뀐다(평탄해지거나 최적점 출현).
#
# 이 실험이 음성이면(ring 을 줄여도 똑같으면) 캐시 워킹셋 해석이 흔들린다.
#
# 전제: MTU 9000 양쪽, governor performance, combined 1, 전 msi_irq -> cpu1,
#       irqbalance masked, adaptive-rx off, autotune/shed = 0
set -u
DUR="${1:-15}"; REPS="${2:-1}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/ringxbuf_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0

for h in sslab3 sslab4; do
  m=$(ssh $h "ip link show $IF" | grep -o 'mtu [0-9]*' | awk '{print $2}')
  [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }
done
ssh sslab4 "uname -r; ethtool -g $IF | grep -A2 'Current hardware'; cat /sys/devices/system/cpu/cpu1/cache/index2/size /sys/devices/system/cpu/cpu1/cache/index3/size" | tee "$LOG/verify.log"
: > "$LOG/raw.txt"

set_ring() {  # ring 변경은 RQ 재생성 -> IRQ affinity/채널이 리셋될 수 있어 매번 재적용
  ssh sslab4 "sudo ethtool -G $IF rx $1 2>/dev/null; sleep 2;
              sudo ethtool -L $IF combined 1 2>/dev/null; sleep 2;
              for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do
                echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done;
              sudo ethtool -C $IF adaptive-rx off 2>/dev/null || true" >/dev/null 2>&1
}

one() {  # one <ring> <capname> <bytes> <rate> <rep>
  local ring="$1"; local cap="$2"; local bytes="$3"; local b="$4"; local rep="$5"
  local d="$LOG/r${ring}_${cap}_b${b}_${rep}"; mkdir -p "$d"
  ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes >/dev/null"
  local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
  local SP=$!
  sleep 2
  ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
  local MP=$!
  ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true"
  wait $SP $MP 2>/dev/null || true

  local rx tx loss busy
  rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  tx=$(grep sender   "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
  loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
  busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
  printf "ring=%-5s %-5s b=%-3s r%s | rx=%-6s loss=%-7s busy=%-4s tx=%-6s\n" \
    "$ring" "$cap" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "${tx:-NA}" | tee -a "$LOG/summary.txt"
  echo "$ring $cap $b $rep ${rx:-NA} ${loss:-NA} ${busy:-NA}" >> "$LOG/raw.txt"
}

# ring: 128(2MB) 256(4MB) 512(8MB) 1024(16MB, 현재기본) 2048(32MB)
#   추정 descriptor page = ring/1024 * 16MB  (MTU 9000, MPWQE 64 pages)
CAPS="256K:262144 512K:524288 1M:1048576 2M:2097152 4M:4194304 8M:8388608"
RINGS="128 256 512 1024 2048"

for rep in $(seq 1 $REPS); do
  for ring in $RINGS; do
    set_ring "$ring"
    actual=$(ssh sslab4 "ethtool -g $IF | awk '/Current hardware/{f=1} f&&/^RX:/{print \$2; exit}'")
    echo "===== ring=$ring (실제 적용=$actual) rep=$rep =====" | tee -a "$LOG/summary.txt"
    for b in 0 46; do
      for c in $CAPS; do one "$ring" "${c%%:*}" "${c##*:}" "$b" "$rep"; done
      echo "" | tee -a "$LOG/summary.txt"
    done
  done
done

set_ring 1024
ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt"
