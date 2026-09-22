#!/bin/bash
# remote_build_618.sh — 대상 호스트에서 실행되는 6.18.53 빌드 스크립트.
#   usage: remote_build_618.sh <localversion> [patchfile]
#   예: remote_build_618.sh -vanilla618
#       remote_build_618.sh -udpopt618 ~/kbuild618/0009-...patch
#
# 안전: 커널 설치 후 grub 기본값은 건드리지 않고, 호출 측에서 grub-reboot 로
#       one-shot 부팅시킨다. 새 커널이 못 뜨면 다음 부팅에 기존 커널로 복귀.
set -euo pipefail
LV="$1"; PATCHFILE="${2:-}"
V=6.18.53
D=~/kbuild618/linux-$V
LOG=~/kbuild618/build${LV}.log

mkdir -p ~/kbuild618
cd ~/kbuild618
if [ ! -f linux-$V.tar.xz ]; then
  curl -sL -O https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$V.tar.xz
fi
rm -rf "$D"
tar xf linux-$V.tar.xz
cd "$D"

if [ -n "$PATCHFILE" ]; then
  patch -p1 --no-backup-if-mismatch < "$PATCHFILE"
  echo "PATCH APPLIED: $PATCHFILE"
fi

cp /boot/config-6.6.9 .config
# 배포판 config 의 서명 키 설정은 자체 빌드에서 실패 원인이므로 비운다.
./scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
./scripts/config --set-str LOCALVERSION "$LV"
./scripts/config --disable LOCALVERSION_AUTO
# HARDENED_USERCOPY 의 per-frag 경계 검사(__check_object_size)가 copyout 핫패스에
# 있다. 6.6.9 에서 고정 부하 기준 CPU -7.2%p 로 측정됐다. 보안 검사를 끄는 것이므로
# 연구용 빌드에서만 쓴다.  NOHARDENED=0 으로 끌 수 있다.
if [ "${NOHARDENED:-1}" = 1 ]; then
  ./scripts/config --disable HARDENED_USERCOPY
fi
make olddefconfig >/dev/null

echo "=== building $V$LV with -j$(nproc) ==="
date
make -j"$(nproc)" > "$LOG" 2>&1
# STRIP 필수: 없으면 initrd 가 1.4GB 로 부풀어 부팅이 멈춘다.
sudo make modules_install INSTALL_MOD_STRIP=1 >> "$LOG" 2>&1
sudo make install >> "$LOG" 2>&1
sudo update-grub >> "$LOG" 2>&1
date
echo "=== installed: $(ls /boot/vmlinuz-${V}${LV}) ==="
