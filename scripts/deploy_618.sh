#!/bin/bash
# deploy_618.sh — 6.18.53 을 두 실험 서버에 배포한다.
#   sslab3 (sender)   : 순정 6.18.53-vanilla618
#   sslab4 (receiver) : 6.18.53-udpopt618  (0009 패치, 두 기능 모두 sysctl default-off)
#
#   usage: deploy_618.sh build          # 빌드+설치만 (재부팅 안 함)
#          deploy_618.sh bootonce <host>  # 새 커널로 one-shot 부팅
#
# 안전장치: grub 기본 엔트리는 바꾸지 않는다. grub-reboot 로 next_entry 만
#   세팅하므로, 새 커널이 못 뜨면 다음 부팅에 기존 커널로 자동 복귀한다.
#   그래도 완전히 hang 하면 IPMI(/dev/ipmi0) 로 전원 복구가 필요하다.
set -u
ACT="${1:-}"
PATCH=~/lab/reports/patches/0009-udp-rx-autotune-and-shed-6.18.patch
V=6.18.53

case "$ACT" in
build)
  scp -q ~/lab/scripts/remote_build_618.sh sslab3:~/
  scp -q ~/lab/scripts/remote_build_618.sh sslab4:~/
  ssh sslab4 "mkdir -p ~/kbuild618"
  scp -q "$PATCH" sslab4:~/kbuild618/
  echo "--- sslab3: vanilla build 시작 (백그라운드) ---"
  ssh sslab3 "chmod +x ~/remote_build_618.sh; nohup ~/remote_build_618.sh -vanilla618 > ~/kbuild618_driver.log 2>&1 &" </dev/null
  echo "--- sslab4: udpopt build 시작 (백그라운드) ---"
  ssh sslab4 "chmod +x ~/remote_build_618.sh; nohup ~/remote_build_618.sh -udpopt618 ~/kbuild618/$(basename $PATCH) > ~/kbuild618_driver.log 2>&1 &" </dev/null
  echo "진행 확인: ssh <host> 'tail -3 ~/kbuild618_driver.log; tail -3 ~/kbuild618/build*.log'"
  ;;
status)
  for h in sslab3 sslab4; do
    echo "=== $h ==="
    ssh $h "tail -4 ~/kbuild618_driver.log 2>/dev/null; ls -la /boot/vmlinuz-${V}* 2>/dev/null || echo '아직 설치 전'"
  done
  ;;
bootonce)
  H="${2:?host required}"
  LV=$([ "$H" = sslab3 ] && echo -vanilla618 || echo -udpopt618)
  ENTRY=$(ssh $H "grep -oP \"menuentry '[^']*${V}${LV}[^']*'\" /boot/grub/grub.cfg | head -1 | sed \"s/menuentry '//; s/'$//\"")
  [ -n "$ENTRY" ] || { echo "FATAL: $H 에서 ${V}${LV} grub 엔트리를 못 찾음"; exit 1; }
  echo "$H -> one-shot 부팅 대상: $ENTRY"
  ssh $H "sudo grub-reboot 'Advanced options for Ubuntu>$ENTRY' && sudo grub-editenv list"
  echo "이제 수동으로: ssh $H 'sudo reboot'"
  ;;
*)
  echo "usage: $0 {build|status|bootonce <host>}"; exit 2;;
esac
