#!/bin/bash
# udp_cache_governor.sh — 실제 LLC 점유를 보고 udp_rmem_cache_pct 를 조절한다
#
# 커널은 예산의 **메커니즘**만 제공한다. 분수를 정적 50% 로 둔 이유는 커널이
# 두 가지를 볼 수 없기 때문이다:
#   - NIC ring 이 캐시를 얼마나 먹는지 (드라이버 내부, 일반 API 없음)
#   - 같은 LLC 를 쓰는 다른 코어가 얼마나 먹는지
#
# 그런데 Intel CMT(`cqm_occup_llc`)는 **실제 점유를 하드웨어가 보고한다.**
# resctrl 감시 그룹으로 읽어 "UDP 수신 코어가 실제로 쓸 수 있는 몫"을 추정하고
# 분수를 맞춘다. 정책은 userspace, 메커니즘은 커널 — resctrl 의 일반적 사용 방식.
#
# 동작:
#   others = (전체 LLC 점유) - (우리 그룹 점유)
#   avail  = LLC - others - ring_bytes
#   pct    = clamp(avail / LLC * 100 * headroom, min, max)
#
# ring_bytes 는 여전히 커널이 모르므로 인자로 받는다. mlx5 + MTU9000 기준
#   ring_entries/1024 * 16MB.
#
#   usage: udp_cache_governor.sh [interval_s] [ring_bytes] [headroom_pct]
#          once 를 첫 인자로 주면 한 번만 계산하고 끝낸다(측정용).
set -u
MODE="${1:-daemon}"
INTERVAL="${2:-2}"; RING_BYTES="${3:-2097152}"; HEADROOM="${4:-80}"
GRP=/sys/fs/resctrl/udprx
MINPCT=5; MAXPCT=90

llc_bytes() {
  # 커널이 감지한 값과 같은 출처를 쓴다
  local sz
  sz=$(cat /sys/devices/system/cpu/cpu1/cache/index3/size 2>/dev/null)
  case "$sz" in *K) echo $(( ${sz%K} * 1024 ));; *M) echo $(( ${sz%M} * 1024 * 1024 ));; *) echo 0;; esac
}
occ() {  # occ <dir>  — 소켓0 만 읽는다 (cpu1 이 있는 소켓)
  cat "$1"/mon_data/mon_L3_00/llc_occupancy 2>/dev/null || echo 0
}

# 우리를 뺀 **활발히 경쟁 중인** 그룹들의 점유 합.
#
#   두 번 틀린 끝에 나온 정의다.
#   1) root 그룹은 자식 그룹에 배정되지 않은 CPU 만 센다. 경쟁자가 별도 그룹에
#      있으면 root 에 안 잡힌다 - total-ours 로 계산했다가 11MB 를 점유한 이웃을
#      2MB 로 읽었다.
#   2) 점유량(llc_occupancy)은 RMID 태그가 붙은 **상주 라인**을 센다. 더 이상
#      쓰이지 않는 죽은 라인도 포함되므로, 아무도 안 돌 때조차 16MB 가 "점유"로
#      나온다. 그 라인들은 요구 시 공짜로 축출되므로 경쟁이 아니다.
#
#   그래서 대역폭(mbm_local_bytes)으로 활성 여부를 가른다: 실제로 캐시를 다투는
#   그룹만 DRAM 트래픽을 만든다. 측정: 이웃이 놀 때 0 MB/s(점유 5MB),
#   스래싱할 때 246 MB/s(점유 11MB).
BWMIN_MB=50
bw_of() {  # bw_of <dir> — 1 회 샘플 간격 동안의 MB/s
  local a b
  a=$(cat "$1"/mon_data/mon_L3_00/mbm_local_bytes 2>/dev/null || echo 0)
  sleep 0.3
  b=$(cat "$1"/mon_data/mon_L3_00/mbm_local_bytes 2>/dev/null || echo 0)
  echo $(( (b - a) * 10 / 3 / 1048576 ))
}
others_occ() {
  local sum=0 d
  for d in /sys/fs/resctrl /sys/fs/resctrl/*/; do
    d="${d%/}"
    [ -d "$d/mon_data" ] || continue
    [ "$d" = "$GRP" ] && continue
    [ "$(bw_of "$d")" -ge $BWMIN_MB ] || continue    # 유휴 그룹은 경쟁자가 아니다
    sum=$(( sum + $(occ "$d") ))
  done
  echo "$sum"
}

LLC=$(llc_bytes)
[ "$LLC" -gt 0 ] || { echo "FATAL: LLC 크기를 못 읽음"; exit 1; }

step() {
  local ours others avail pct
  ours=$(occ "$GRP")
  others=$(others_occ)
  avail=$(( LLC - others - RING_BYTES ))
  [ "$avail" -lt 0 ] && avail=0
  pct=$(( avail * 100 / LLC * HEADROOM / 100 ))
  [ "$pct" -lt $MINPCT ] && pct=$MINPCT
  [ "$pct" -gt $MAXPCT ] && pct=$MAXPCT
  printf "LLC=%dMB ours=%dMB others=%dMB ring=%dMB -> avail=%dMB pct=%d\n" \
    $((LLC>>20)) $((ours>>20)) $((others>>20)) $((RING_BYTES>>20)) $((avail>>20)) "$pct"
  echo "$pct"
}

if [ "$MODE" = once ]; then
  step | tail -2 | head -1
  exit 0
fi

echo "governor 시작: LLC=$((LLC>>20))MB ring=$((RING_BYTES>>20))MB headroom=${HEADROOM}% interval=${INTERVAL}s"
while : ; do
  pct=$(step | tail -1)
  cur=$(sysctl -n net.ipv4.udp_rmem_cache_pct)
  if [ "$pct" != "$cur" ]; then
    sudo sysctl -w net.ipv4.udp_rmem_cache_pct="$pct" >/dev/null
    echo "  udp_rmem_cache_pct: $cur -> $pct"
  fi
  sleep "$INTERVAL"
done
