#!/bin/bash
# probe_quic_scale.sh — QUIC 이 코어를 더 쓰면 커널 수신 경로가 병목이 되는 구간까지
# 올라가는지 정찰한다.
#
# 단일 코어 단일 연결에서 2.93 Gb/s 로 측정됐다 (2GB / 5.87s). 우리 기전이 갈리기
# 시작하는 지점은 ~25 Gb/s 이므로 8.5 배 아래다. 원인은 quiche 의 수신 루프다:
#   const MAX_DATAGRAM_SIZE: usize = 1350;          // apps/src/client.rs:38
#   let (len, from) = socket.recv_from(&mut buf);   // :284, datagram 당 syscall 1회
# UDP_GRO 도 recvmmsg 도 안 쓴다.
#
# 여기서 묻는 것: 클라이언트를 코어마다 하나씩 띄워 합계를 올리면 25 Gb/s 를 넘겨
# 커널 경로가 병목이 되는가. 넘으면 그 구간에서 stock/ours 비교가 의미를 갖는다.
# 못 넘으면 QUIC 으로는 우리 기여를 보일 수 없다는 뜻이고, 그게 결론이다.
#
# 주의: 수신측 코어를 여러 개 쓰므로 단일코어 방법론 밖이다. 정찰 전용.
set -u
CONNS="${1:-1 2 4 8}"
SRV=192.168.11.120
QS='$HOME/quiche/target/release/quiche-server'
QC='$HOME/quiche/target/release/quiche-client'
CERT='$HOME/quiche/apps/src/bin/cert.crt'
KEY='$HOME/quiche/apps/src/bin/cert.key'
BLOB_BYTES=2147483648

ssh sslab3 "mkdir -p ~/quicroot && [ -s ~/quicroot/blob ] || dd if=/dev/zero of=~/quicroot/blob bs=1M count=2048 status=none"
ssh sslab4 "uname -r"

for n in $CONNS; do
  ssh sslab3 "nohup $QS --listen 0.0.0.0:4433 --root \$HOME/quicroot --cert $CERT --key $KEY \
      --max-data 10000000000 --max-stream-data 10000000000 > ~/quic_srv.log 2>&1 &" </dev/null
  sleep 3
  # --dump-responses 는 **존재하는 디렉터리**를 요구한다. 없으면 클라이언트가
  # 즉시 죽고 wait 가 0.04s 만에 돌아와 말이 안 되는 수치가 나온다.
  ssh sslab4 "for c in \$(seq 1 $n); do mkdir -p /tmp/qr\$c; done"
  t0=$(date +%s.%N)
  for c in $(seq 1 "$n"); do
    ssh sslab4 "taskset -c $(( (c % 10) + 1 )) $QC --no-verify --max-data 10000000000 \
        --max-stream-data 10000000000 https://$SRV:4433/blob --dump-responses /tmp/qr$c" \
        > /tmp/quicscale-$c.log 2>&1 &
  done
  wait
  t1=$(date +%s.%N)
  ssh sslab3 "pkill -f '[q]uiche-server' 2>/dev/null; true"
  got=$(ssh sslab4 "cat /tmp/qr*/blob 2>/dev/null | wc -c")
  ssh sslab4 "rm -rf /tmp/qr* 2>/dev/null; true"
  exp=$(( n * BLOB_BYTES ))
  [ "${got:-0}" = "$exp" ] || echo "  WARN 받은 바이트 $got != 기대 $exp"
  awk -v a="$t0" -v b="$t1" -v n="$n" -v B="$BLOB_BYTES" \
    'BEGIN{e=b-a; printf "연결 %-3s  %6.2f s  합계 %6.2f Gb/s  (연결당 %5.2f)\n", n, e, n*B*8/e/1e9, B*8/e/1e9}'
done
