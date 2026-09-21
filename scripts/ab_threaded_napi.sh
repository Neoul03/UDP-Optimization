#!/bin/bash
# ab_threaded_napi.sh — Tier1 #1: threaded NAPI가 우리 shed를 대체하는가?
# threaded NAPI는 NAPI를 softirq가 아닌 kthread로 돌려 consumer와 "공정하게" 경쟁시킨다.
# 그게 starvation을 없애면 driver shed의 존재 이유가 약해진다.
# ⚠️ 진짜 단일코어 유지를 위해 napi kthread도 core1에 핀해야 함 (안 하면 2코어 실험이 됨).
set -u
REPS="${1:-3}"; DUR="${2:-20}"
TS=$(date +%Y%m%d_%H%M%S); LOG=~/lab/logs/threaded_napi_${TS}; mkdir -p "$LOG"
IPERF_MOD=~/iperf3-source/src/iperf3
SRV_IP=192.168.11.238; IF=ens81f0np0

ssh sslab4 "
  sudo ip link set $IF mtu 9000
  for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance | sudo tee \$g >/dev/null; done
  sudo ethtool -L $IF combined 1 2>/dev/null || true; sleep 2
  for irq in \$(ls /sys/class/net/$IF/device/msi_irqs/); do echo 2 | sudo tee /proc/irq/\$irq/smp_affinity >/dev/null 2>&1 || true; done
  echo 0 | sudo tee /sys/class/net/$IF/napi_defer_hard_irqs /sys/class/net/$IF/gro_flush_timeout >/dev/null
  sudo sysctl -w net.core.rmem_max=536870912 net.ipv4.udp_rmem_autotune=0 net.ipv4.udp_early_drop=0 >/dev/null
" > "$LOG/setup.log" 2>&1
ssh sslab3 "sudo ip link set $IF mtu 9000" >> "$LOG/setup.log" 2>&1
for h in sslab3 sslab4; do m=$(ssh $h "ip link show $IF"|grep -o 'mtu [0-9]*'|awk '{print $2}'); [ "$m" = 9000 ] || { echo "FATAL $h mtu=$m"; exit 1; }; done

set_threaded() {  # set_threaded <0/1>  — 켜면 napi kthread를 core1에 핀
  ssh sslab4 "
    echo $1 | sudo tee /sys/class/net/$IF/threaded >/dev/null
    sleep 1
    if [ '$1' = '1' ]; then
      for p in \$(pgrep -f 'napi/$IF'); do sudo taskset -pc 1 \$p >/dev/null 2>&1; done
      echo -n 'napi kthreads pinned: '; pgrep -fc 'napi/$IF'
    fi
    cat /sys/class/net/$IF/threaded
  " 2>&1 | tee -a "$LOG/run.log"
}

point() {  # point <arm> <rmem> <shed> <threaded> <offered> <rep>
  local arm="$1"; local bytes="$2"; local shed="$3"; local thr="$4"; local b="$5"; local rep="$6"
  local try=0 rx tx loss busy d
  while : ; do
    d="$LOG/${arm}_b${b}_r${rep}$([ $try -gt 0 ] && echo _retry$try)"
    mkdir -p "$d"
    ssh sslab4 "sudo sysctl -w net.core.rmem_default=$bytes net.ipv4.udp_rx_shed=$shed >/dev/null"
    local bopt="-b ${b}G"; [ "$b" = "0" ] && bopt="-b 0"
    ssh sslab4 "taskset -c 1 $IPERF_MOD -s -B $SRV_IP -1" > "$d/server.log" 2>&1 &
    local SP=$!
    sleep 2
    ssh sslab4 "mpstat -P 1 1 $DUR" > "$d/mpstat.log" 2>&1 &
    local MP=$!
    ssh sslab3 "taskset -c 1 $IPERF_MOD -c $SRV_IP -u $bopt -l 65000 -t $DUR" > "$d/client.log" 2>&1 || true
    ssh sslab4 "pkill -f 'iperf3 -s' 2>/dev/null; true"
    wait $SP $MP 2>/dev/null || true
    rx=$(grep receiver "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    tx=$(grep sender "$d/client.log"|tail -1|grep -oE '[0-9.]+ Gbits/sec'|head -1|awk '{print $1}')
    loss=$(grep receiver "$d/client.log"|tail -1|grep -oE '\([0-9.]+%\)'|tr -d '()%')
    busy=$(awk '$3=="1" && $4 ~ /^[0-9.]+$/ {n++; if(n>3){id+=$13;m++}} END {if(m)printf "%.0f",100-id/m}' "$d/mpstat.log")
    # 다른 코어로 샌 일 없는지 확인 (threaded면 kthread가 튈 수 있음)
    ssh sslab4 "mpstat -P ALL 1 1 | awk '\$3 ~ /^[0-9]+$/ && (100-\$13) > 20 {print \$3\":\"int(100-\$13)\"%\"}'" > "$d/allcpu.txt" 2>&1
    if [ "$b" != "0" ] && [ -n "$tx" ] && awk -v t="$tx" -v o="$b" 'BEGIN{exit !(t < o*0.97)}'; then
      try=$((try+1)); [ $try -le 2 ] && continue
    fi
    break
  done
  local other; other=$(tr '\n' ' ' < "$d/allcpu.txt" 2>/dev/null)
  printf "%-16s b=%-3s r%s | rx=%-6s loss=%-8s busy=%-4s | cpus:%s\n" "$arm" "$b" "$rep" "${rx:-NA}" "${loss:-NA}%" "${busy:-NA}%" "$other" | tee -a "$LOG/summary.txt"
}

for rep in $(seq 1 $REPS); do
  echo "===== REP $rep =====" | tee -a "$LOG/summary.txt"
  # --- threaded OFF (현재 최적 구성 기준선) ---
  set_threaded 0
  for b in 35 40 0; do
    point "thrOFF_shedON"  1572864 1 0 "$b" "$rep"
    point "thrOFF_shedOFF" 1572864 0 0 "$b" "$rep"
  done
  # --- threaded ON ---
  set_threaded 1
  for b in 35 40 0; do
    point "thrON_shedOFF"  1572864 0 1 "$b" "$rep"   # ★ 관건: threaded만으로 shed 대체되나
    point "thrON_shedON"   1572864 1 1 "$b" "$rep"
  done
  echo "" | tee -a "$LOG/summary.txt"
done
set_threaded 0
ssh sslab4 "sudo sysctl -w net.core.rmem_default=212992 net.ipv4.udp_rx_shed=0 >/dev/null; pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
ssh sslab3 "pgrep -a iperf3 || echo clean" | tee -a "$LOG/summary.txt"
echo "DONE $LOG/summary.txt" | tee -a "$LOG/run.log"
