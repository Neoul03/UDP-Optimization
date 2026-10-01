# v21 커널 수정과 QUIC 실험 (2026-10-01 야간)

## 1. 커널 v21 — `SO_RCVBUF` 를 하한으로 재해석

### 고친 것

`udp_rcvbuf_autotune()` 이 `SOCK_RCVBUF_LOCK` 소켓 앞에서 물러서던 것을 멈췄다.

```c
/* v20 */
if (sk->sk_userlocks & SOCK_RCVBUF_LOCK) {
        ...계상만...
        return rcvbuf;                 /* sizing 통째로 꺼짐 */
}

/* v21 */
if (sk->sk_userlocks & SOCK_RCVBUF_LOCK)
        atomic_cmpxchg(&up->rcvbuf_user, 0, (int)rcvbuf);   /* 하한으로 기록, 계속 진행 */
```

같이 바뀐 것:
- `struct udp_sock` 에 `rcvbuf_user` 추가. 축소 바닥이 `max(target, rmem_default, rcvbuf_user)` 가 된다.
- `udp_budget_sweep()` 이 `SOCK_RCVBUF_LOCK` 소켓을 건너뛰지 않는다. 자기가 준 분만, `rcvbuf_user` 위에서만 회수한다. (기존엔 통째로 건너뛰어 그 소켓의 grant 가 영영 회수되지 않았다.)
- sweep 의 유휴 분기에 `rmem_default` 바닥이 없던 불일치도 같이 고쳤다. 도착 경로가 지키는 바닥을 sweep 이 무너뜨릴 수 있었다.

### 왜 필요했나

TCP 의 관례를 그대로 베낀 것이 틀렸다. TCP 에서 그 관례가 무해한 이유는 DRS 가
2004 년부터 돌아서 **앱이 `SO_RCVBUF` 를 부를 이유가 없기** 때문이다. UDP 는
반대다 — 아무것도 버퍼를 안 정해주니 앱이 **어쩔 수 없이** 부르고, 그 방어 행동이
해법을 꺼버렸다.

그리고 존중하던 값이 앱의 의사도 아니었다: `__sock_set_rcvbuf()`(`net/core/sock.c`)
가 요청을 `rmem_max` 로 자르고 **에러를 안 돌려준다.** 64 MB 요청이 416 KB 가
되고 `setsockopt` 는 성공을 반환한다.

### 검증 (MTU 9000, 65 G, 단일 flow, 단일 코어)

| 앱 동작 | v20 | **v21** |
|---|---|---|
| `SO_RCVBUF` 호출 | `rb 425,984` / **29.62** | **`rb 8,387,328`** / **54.23** |
| 호출 안 함 | `rb 3,749,760` / 61.42 | `rb 3,610,880` / **62.07** |

**+83% 회수**, 미호출 경로 회귀 없음. 부팅 로그 정상
(`receive budget sized from L3 cache (18432 KiB)`).

### ★ 짚어둘 것: 끝나는 버퍼 크기가 출발점에 의존한다

호출한 쪽은 **8.39 MB**(예산 상한)에서 멈추고, 안 부른 쪽은 **3.61 MB** 에서 멈춘다.
`target = 2 x 비움주기 소비량` 인데, 버퍼가 크면 주기가 길어져 그 주기의 소비량도
커진다 — 즉 `target` 이 버퍼 크기에 양의 되먹임을 갖는다. 예산이 그걸 막아 주지만,
**"유도된 목표" 가 이력과 무관한 고정점은 아니다.**

그리고 결과적으로 8.39 MB 쪽이 3.61 MB 쪽보다 **느리다** (54.23 vs 62.07). 캐시
이야기와 일관된다 — 8 MB 는 이미 단맛 구간을 지났다. 즉 v21 은 큰 개선이지만
`SO_RCVBUF` 를 부르는 앱을 미호출 앱 수준까지 끌어올리지는 못한다.

---

## 2. QUIC — 실험 전에 코드로 확인한 것

`quiche` 를 양쪽에 빌드했다 (rustup + cmake 3.28 tarball; 20.04 의 apt cmake
3.16 은 BoringSSL 요구치 3.22 미만이라 못 쓴다. sslab3 엔 clang 이 없어 bindgen 이
실패해서 sslab4 에서 빌드한 바이너리를 복사했다 — 같은 20.04.6 / GLIBC 2.31).

`apps/src/client.rs` 를 읽으면 **QUIC 수신 경로가 우리가 최적화한 기전을 하나도
쓰지 않는다**:

```rust
const MAX_DATAGRAM_SIZE: usize = 1350;          // :38   MTU 9000 과 무관
config.set_max_recv_udp_payload_size(MAX_DATAGRAM_SIZE);
let (len, from) = socket.recv_from(&mut buf);   // :284  datagram 당 syscall 하나
```

- `setsockopt(UDP_GRO)` 미호출 -> `udp_rcv_segment()` 가 커널이 합친 skb 를 도로 쪼갠다
- `setsockopt(SO_RCVBUF)` 미호출 -> 208 KB 기본값 (그래서 **v21 수정도 quiche 에는 무관**)
- `recvmmsg` 미사용

## 3. 측정된 천장

| | |
|---|---|
| 단일 연결, 단일 코어 | **2.93 Gb/s** (2 GB / 5.87 s) |
| 수신측 코어를 늘려 1/2/4/8 연결 | **3.42 / 3.66 / 3.56 / 3.67** — 합계가 안 오른다 |

연결 수를 늘려도 합계가 ~3.5 Gb/s 에 고정된다. **`quiche-server` 가 단일 스레드
이벤트 루프**라 송신측이 병목이다.

## 4. 그래서 QUIC 으로는 이 기여를 보일 수 없다 — 세 겹의 이유

```
우리 기전이 갈리기 시작하는 지점      ~25 Gb/s   (그 아래는 stock 과 완전히 동일)
QUIC 단일코어 수신 천장               ~2.9 Gb/s
QUIC 송신 천장 (단일 스레드 서버)     ~3.5 Gb/s
```

**8.5 배 아래**다. 그리고 그 아래에서는 우리 커널과 기존 커널이 측정상 구별되지
않는다 (사다리: 5/10/15/20 G 에서 세 arm 전부 동일).

이건 우리 기여가 쓸모없다는 뜻이 아니라 **오늘의 QUIC 구현이 커널이 제공하는 배치
기전(GRO, recvmmsg, 큰 버퍼)을 안 쓴다**는 뜻이다. 그 자체가 보고할 만한 사실이고,
"수신 경로를 고쳐도 앱이 안 쓰면 소용없다" 는 이 논문의 P1 과 같은 구조다 — 앱이
커널에게 무엇을 원하는지 말할 방법이 없다는 문제.

## 5. 한계

- 구현 하나(quiche)만 봤다. msquic / Chromium 은 GRO 와 `recvmmsg` 를 쓴다고
  알려져 있으나 이 세션에서 소스로 확인하지 않았다 — (c).
- `quiche-server` 가 단일 스레드라 송신이 먼저 막혔다. 다중 서버 프로세스로
  올리면 수신측을 더 밀 수 있지만, 그래도 수신 천장(2.9 G/코어)이 먼저 걸린다.
- 단일코어 방법론 밖의 정찰(코어 여러 개)은 참고용이다.
