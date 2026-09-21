#!/bin/bash
# trials_server_sticky.sh — 상태가 "서버 프로세스 인스턴스"에 귀속되는가?
# 서버를 -1 없이 상주(로컬 ssh를 백그라운드로 유지)시키고 client 런을 K회 연속 실행.
# 같은 인스턴스 내 상태가 묶이면 원인은 프로세스별 메모리 레이아웃(cache coloring 등).
set -u
INSTANCES="${1:-6}"; K="${2:-5}"; RATE="${3:-46}"; DUR="${4:-12}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/sticky_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3; SRV_IP=192.168.11.238; IF=ens81f0np0
ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/threaded /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null 2>&1 || true
  sudo ethtool -C $IF adaptive-rx off 2>/dev/null || true
  sudo sysctl -w net.core.rmem_max=536870912 net.core.rmem_default=1572864 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_early_drop=0 net.ipv4.udp_rx_shed=0 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1

for inst in $(seq 1 $INSTANCES); do
  # 상주 서버: 로컬에서 ssh를 백그라운드로 유지 (K회 client 런 동안 살아있음)
  ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP" > "$LOG/srv_${inst}.log" 2>&1 &
  SPID=$!
  sleep 3
  printf "inst%-2s: " "$inst" | tee -a "$LOG/summary.txt"
  for k in $(seq 1 $K); do
    d="$LOG/i${inst}_k${k}"; mkdir -p "$d"
    ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u -b ${RATE}G -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    if [ -z "$tx" ] || awk -v t="${tx:-0}" -v o="$RATE" 'BEGIN{exit !(t < o*0.97)}'; then st="FLAKE"
    elif awk -v l="${loss:-100}" 'BEGIN{exit !(l < 1)}'; then st="GOOD"; else st="BAD"; fi
    echo "inst$inst k$k $st rx=$rx loss=${loss}%" >> "$LOG/raw.txt"
    printf "%s" "$(echo $st|cut -c1)" | tee -a "$LOG/summary.txt"
    sleep 1
  done
  echo "" | tee -a "$LOG/summary.txt"
  kill $SPID 2>/dev/null || true
  ssh sslab4 "pkill -f '[i]perf3 -s' 2>/dev/null; true" >/dev/null 2>&1
  sleep 1
done
ssh sslab4 "sudo ethtool -C $IF adaptive-rx on 2>/dev/null; sudo sysctl -w net.core.rmem_default=212992 >/dev/null; pgrep -a '[i]perf3' || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
