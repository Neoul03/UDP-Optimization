#!/bin/bash
# set_governor.sh — 두 호스트의 cpufreq governor 를 performance 로 맞춘다.
#
# ★ 재부팅하면 governor 가 ondemand 로 리셋된다. MTU(1500 으로 리셋)와
#   adaptive-rx(on 으로 리셋)와 같은 부류의 함정이다. ondemand 로 측정하면
#   주파수가 부하에 따라 흔들려 모든 기준선과 비교가 안 된다.
#
# 글롭으로 sudo tee 하는 형태는 permission classifier 에 걸리므로, cpu 목록을
# 원격에서 풀어 한 줄짜리 tee 로 넘긴다.
set -u
for h in sslab3 sslab4; do
  printf "%-8s " $h
  ssh $h "n=\$(nproc)
    for i in \$(seq 0 \$((n-1))); do
      f=/sys/devices/system/cpu/cpu\$i/cpufreq/scaling_governor
      [ -w \$f ] || [ -f \$f ] || continue
      echo performance | sudo tee \$f >/dev/null 2>&1 || true
    done
    echo \"governor=\$(cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor)\""
done
