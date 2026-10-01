#!/bin/bash
# setup_quiche.sh — 두 호스트에 Rust + quiche 를 설치한다.
#
# QUIC 을 고른 이유: 우리 수신 경로를 100% 타는 유일한 실제 프로토콜이다.
# (VXLAN/GTP/L2TP/WireGuard/ESP-in-UDP 는 encap_rcv 훅에서 빠져 sk_rcvbuf 를
#  안 쓰고, HW RoCEv2 는 커널에 들어오지도 않는다.)
#
# rustup 은 사용자 홈에 깔리므로 sudo 가 필요 없다. apt 는 NOPASSWD 목록에
# 없으므로 쓰지 않는다.
#
# quiche 의 apps 예제가 quiche-server / quiche-client 를 준다. HTTP/3 로
# 파일을 받는 형태라 처리량 측정에 쓸 수 있다.
set -u
ACT="${1:-}"
HOSTS="sslab3 sslab4"

case "$ACT" in
install)
  # quiche 는 boring-sys(BoringSSL)를 거쳐 cmake 를 부른다. 20.04 의 apt cmake 는
  # 3.16 이고 BoringSSL 은 3.22+ 를 요구하므로, 공식 바이너리 tarball 을 홈에 푼다.
  # 시스템 cmake 는 건드리지 않고 PATH 로만 앞세운다.
  CMV=3.28.6
  for h in $HOSTS; do
    printf "%s: cmake " $h
    ssh $h "if [ -x ~/opt/cmake/bin/cmake ]; then echo \"이미 있음 \$(~/opt/cmake/bin/cmake --version|head -1)\"; exit 0; fi
            mkdir -p ~/opt && cd /tmp &&
            curl -sSL -o cm.tgz https://github.com/Kitware/CMake/releases/download/v$CMV/cmake-$CMV-linux-x86_64.tar.gz &&
            tar xzf cm.tgz && rm -rf ~/opt/cmake && mv cmake-$CMV-linux-x86_64 ~/opt/cmake && rm -f cm.tgz &&
            echo \"설치됨 \$(~/opt/cmake/bin/cmake --version|head -1)\" || echo 'FATAL cmake 설치 실패'" </dev/null
  done
  for h in $HOSTS; do
    echo "=== $h: rustup ==="
    ssh $h "command -v cargo >/dev/null 2>&1 && { echo 'cargo 이미 있음'; exit 0; }
            curl -sSf https://sh.rustup.rs -o /tmp/rustup.sh &&
            sh /tmp/rustup.sh -y --profile minimal --default-toolchain stable >/dev/null 2>&1 &&
            echo 'rustup 설치됨'" </dev/null
  done
  for h in $HOSTS; do
    echo "=== $h: quiche clone+build (백그라운드) ==="
    ssh $h "export PATH=\$HOME/opt/cmake/bin:\$HOME/.cargo/bin:\$PATH
            [ -d ~/quiche ] || git clone -q --recursive https://github.com/cloudflare/quiche.git ~/quiche
            cd ~/quiche && nohup env PATH=\$PATH cargo build --release --bin quiche-server --bin quiche-client \
                > ~/quiche_build.log 2>&1 &" </dev/null
  done
  echo "진행 확인:  $0 status"
  ;;
status)
  for h in $HOSTS; do
    printf "%s: " $h
    ssh $h "export PATH=\$HOME/.cargo/bin:\$PATH
            command -v cargo >/dev/null && printf 'cargo=%s ' \$(cargo --version 2>/dev/null | awk '{print \$2}')
            if [ -x ~/quiche/target/release/quiche-server ] && [ -x ~/quiche/target/release/quiche-client ]; then
                echo 'quiche BUILT'
            else
                echo \"building... \$(tail -1 ~/quiche_build.log 2>/dev/null | cut -c1-90)\"
            fi"
  done
  ;;
wait)
  while :; do
    n=0
    for h in $HOSTS; do
      ssh $h "[ -x ~/quiche/target/release/quiche-server ] && [ -x ~/quiche/target/release/quiche-client ]" && n=$((n+1))
    done
    [ "$n" = 2 ] && { echo "quiche READY on both"; exit 0; }
    for h in $HOSTS; do
      ssh $h "grep -qiE '^error|error\[' ~/quiche_build.log 2>/dev/null" && {
        echo "FATAL $h 빌드 에러:"; ssh $h "tail -20 ~/quiche_build.log"; exit 1; }
    done
    sleep 60
  done
  ;;
copy)
  # sslab3 에는 clang 이 없어 boring-sys 의 bindgen 이 stddef.h 를 못 찾는다
  # (sslab4 에만 /usr/bin/clang 이 있다). 두 호스트는 Ubuntu 20.04.6 /
  # GLIBC 2.31 로 완전히 같으므로 빌드된 바이너리를 그대로 옮긴다.
  # (WSL 에서 빌드해 서버로 보내는 것은 glibc 가 더 최신이라 안 되지만,
  #  서버끼리는 같은 이미지라 괜찮다.)
  SRC=sslab4; DST=sslab3
  ssh $SRC "[ -x ~/quiche/target/release/quiche-server ]" || { echo "FATAL $SRC 에 빌드물이 없다"; exit 1; }
  ssh $DST "mkdir -p ~/quiche/target/release ~/quiche/apps/src/bin"
  for f in quiche-server quiche-client; do
    ssh $SRC "cat ~/quiche/target/release/$f" | ssh $DST "cat > ~/quiche/target/release/$f && chmod +x ~/quiche/target/release/$f"
  done
  # 서버가 쓰는 자체 서명 인증서도 같이 (기본 경로가 apps/src/bin/cert.*)
  for f in cert.crt cert.key; do
    ssh $SRC "cat ~/quiche/apps/src/bin/$f" | ssh $DST "cat > ~/quiche/apps/src/bin/$f"
  done
  ssh $DST "~/quiche/target/release/quiche-server --help >/dev/null 2>&1 && echo 'sslab3 quiche-server 실행 확인' || echo 'FATAL 실행 안 됨'"
  ;;
*)
  echo "usage: $0 {install|status|wait|copy}"; exit 2 ;;
esac
