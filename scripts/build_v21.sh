#!/bin/bash
# build_v21.sh — 0009 v21 (SO_RCVBUF 를 하한으로) 을 sslab4 에 빌드/설치한다.
#
# v21 이 바꾸는 것:
#   udp_rcvbuf_autotune() 이 SOCK_RCVBUF_LOCK 소켓 앞에서 물러서지 않는다.
#   앱이 SO_RCVBUF 로 명시한 크기는 **하한**이 되고, 측정된 수요와 캐시 예산이
#   허락하는 만큼 그 위로 자란다. 축소는 그 하한 아래로 못 내려간다.
#   udp_budget_sweep() 도 같은 하한을 지키며 자기가 준 분만 회수한다.
#
#   필요한 이유: 고속 UDP 앱은 대체로 SO_RCVBUF 를 부르는데 (기본 208KB 로는
#   못 버티니까), v20 까지는 그 호출이 우리 sizing 을 통째로 꺼버렸다.
#   측정된 비용 평균 -32%, MTU 9000 에서 -49%.
#
# 사용:
#   build_v21.sh build    패치 전송 + 빌드 시작 (백그라운드)
#   build_v21.sh wait     READY 가 뜰 때까지 대기. 뜨면 0, 실패면 1
#   build_v21.sh check    설치물 네 가지를 다시 확인만
#
# ★ 재부팅은 이 스크립트가 하지 않는다. READY 확인 후 사람이/호출측이 따로 한다.
set -u
H=sslab4
V=6.18.53
LV=-udpopt21
P=~/lab/reports/patches/0009-v21.patch
ACT="${1:-}"

case "$ACT" in
build)
  [ -s "$P" ] || { echo "FATAL 패치가 없다: $P"; exit 1; }
  # ★ 호스트에 있는 사본이 실행된다. 로컬만 고치고 scp 를 잊으면 방지 장치가
  #   없는 구 버전이 돈다 (v18 에서 실제로 그랬다).
  scp -q ~/lab/scripts/remote_build_618.sh $H:
  ssh $H "mkdir -p kbuild618"
  scp -q "$P" $H:kbuild618/0009-v21.patch
  ssh $H "chmod +x remote_build_618.sh"
  echo "--- $H: $V$LV 빌드 시작 ---"
  # ★ 절대경로여야 한다. remote_build_618.sh 는 patch 적용 전에 커널 트리로
  #   cd 하므로 상대경로는 거기서 풀린다.
  ssh $H "nohup ./remote_build_618.sh $LV \$HOME/kbuild618/0009-v21.patch > kbuild618_driver.log 2>&1 &" </dev/null
  sleep 15
  ssh $H "tail -3 kbuild618_driver.log"
  echo "대기:  $0 wait"
  ;;
wait)
  echo "READY 를 기다린다 (vmlinuz 가 아니라 initrd 까지 끝나야 한다)..."
  while :; do
    out=$(ssh $H "tail -6 kbuild618_driver.log 2>/dev/null")
    case "$out" in
      *READY*)      echo "$out"; exit 0 ;;
      *"NOT READY"*|*FATAL*|*Error*|*error:*)
                    echo "$out"; echo "빌드 실패 - 부팅하지 말 것"; exit 1 ;;
    esac
    sleep 60
  done
  ;;
check)
  ssh $H "V_FULL=$V$LV
    ls -la /boot/vmlinuz-\$V_FULL /boot/initrd.img-\$V_FULL 2>&1
    echo \"modules: \$(find /lib/modules/\$V_FULL -name '*.ko*' 2>/dev/null | wc -l)\"
    echo \"grub   : \$(grep -c \$V_FULL /boot/grub/grub.cfg)\"
    echo \"현재 커널: \$(uname -r)\""
  ;;
boot)
  # 네 가지를 다시 확인하고 나서만 띄운다. vmlinuz 만 보고 띄웠다가 initrd 생성
  # 중에 죽여서 부팅 불가가 된 적이 있다 (2026-09-25).
  V_FULL=$V$LV
  ssh $H "set -e
    [ -s /boot/vmlinuz-$V_FULL ]
    [ \$(stat -c%s /boot/initrd.img-$V_FULL) -gt 20000000 ]
    [ \$(find /lib/modules/$V_FULL -name '*.ko*' | wc -l) -gt 1000 ]
    grep -q $V_FULL /boot/grub/grub.cfg" || { echo "FATAL 설치물 확인 실패 - 부팅하지 않는다"; exit 1; }
  ENTRY=$(ssh $H "grep -oP \"menuentry '[^']*${V_FULL}[^']*'\" /boot/grub/grub.cfg | head -1 | sed \"s/menuentry '//; s/'\$//\"")
  [ -n "$ENTRY" ] || { echo "FATAL grub 엔트리를 못 찾음"; exit 1; }
  echo "one-shot 대상: $ENTRY"
  # grub 기본값은 건드리지 않는다. 새 커널이 패닉하면 다음 부팅에 구 커널로 복귀한다.
  # (단 완전히 hang 하면 전원 사이클이 필요하고, 이 호스트는 BMC 주소가 없다.)
  ssh $H "sudo grub-reboot 'Advanced options for Ubuntu>$ENTRY' && sudo grub-editenv list"
  echo "재부팅..."
  ssh $H "sudo systemctl reboot" || true
  sleep 45
  for i in $(seq 1 40); do
    k=$(ssh -o ConnectTimeout=5 -o BatchMode=yes $H "uname -r" 2>/dev/null) && [ -n "$k" ] && {
      echo "복귀: $k"
      [ "$k" = "$V_FULL" ] && { echo "OK v21 로 부팅됨"; exit 0; }
      echo "경고: 구 커널로 돌아왔다 ($k). 새 커널이 못 떴다."; exit 1; }
    sleep 15
  done
  echo "FATAL 4xx초 동안 SSH 복귀 없음 - hang 가능성. 전원 사이클 필요."
  exit 1
  ;;
*)
  echo "usage: $0 {build|wait|check|boot}"; exit 2 ;;
esac
