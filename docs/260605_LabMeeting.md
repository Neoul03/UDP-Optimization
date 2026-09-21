# 2026-06-05 Lab Meeting — "lock을 amortize해봤더니: 진짜 병목은 lock이 아니었다"
### negative result 연쇄 → UDP_GRO + DIM off로 UDP가 TCP를 넘기까지

작성: 2026-06-04
환경: sslab4(receiver) / sslab3(sender) / CX5 mlx5_core / `ens81f0np0` / 192.168.11.{120,238} / MTU 9000 / CPU1 핀 / kernel 6.6.9
지난주(05-29)에 **"UDP receive가 packet-당-lock 구조라 DIM burst를 amortize 못 한다 → lock batch로 amortize하자"**(Slide 7-8)로 마무리. **이번 주는 그 제안을 실제로 구현·검증한 결과.**

> **한 줄 결론:** lock batch는 구현해서 lock을 6.7배 줄였지만 **throughput은 안 변했다(병목 아님).** 진단을 정정해가며 도달한 진짜 답은 **GSO + GRO(재분해 제거)** — **진짜 단일코어(NIC IRQ까지 core1 핀)에서 UDP가 TCP와 동급(~44G)에 도달**하고, **UDP_GRO가 +51% lever**다. lock·DIM·RX스티어링은 lever가 아니었다.

---

## Slide 1 — 지난주 제안과 이번 주 검증 계획

지난주 결론(재확인):
- (a) UDP는 datagram당 `__udp_enqueue_schedule_skb`에서 lock 1회 (`net/ipv4/udp.c:1488`)
- (a) TCP는 `lock_sock` 1회로 다수 skb drain → bytes/recvmsg TCP 947KB vs UDP 35KB (27× amortized)
- 제안: producer enqueue를 **list 버전**으로 만들어 lock 1회에 N skb (Plan A)

이번 주 실행: **Plan A 구현 → 커널 빌드/부팅 → 통제 A/B로 효과 측정.** "정말 lock이 병목인가"를 코드 수정으로 직접 반증/입증한다.

---

## Slide 2 — Plan A 구현: producer batch enqueue (patch 0003)

- 신규 `__udp_enqueue_schedule_skb_list(sk, batch)`: GRO super-skb의 segment list를 **단일 `sk_receive_queue.lock` + 단일 forward-alloc schedule + 단일 `sk_data_ready`**로 enqueue.
  - Phase1(lockless): skb별 rmem charge/overflow 판정 (drop 회계 단일-skb 경로와 동일 보존)
  - Phase2(lock 1회): `skb_queue_splice_tail`로 통째 삽입
  - Phase3: wakeup 1회 + drop 회계
- `udp_queue_rcv_skb`의 segment loop(`udp.c:2190`)가 batch 모은 뒤 끝에서 list enqueue 1회.
- **커널 빌드·부팅:** vanilla 6.6.9 + patch, `/boot/config-6.6.9` 그대로, `6.6.9-udpbatch`로 sslab4 부팅.
  - (교훈) 빌드 함정: 모듈 strip 안 하면 initrd 1.4GB → 부팅 hang. `INSTALL_MOD_STRIP=1` → 142MB 정상.

`reports/patches/0003-udp-batch-enqueue-gro-segments.patch`

---

## Slide 3 — ★ 결과 1 (negative): lock 6.71x↓, throughput 무변화

(a) bpftrace, `-l 8972` non-frag, GRO 머지 ~6.7:

| 카운터 | 값 | 의미 |
|---|---|---|
| `udp_queue_rcv_one_skb` (datagram) | 17.06M | |
| `__udp_enqueue_schedule_skb` (구 per-skb lock) | **5,621** | **datagram의 0.08%만** |
| → lock 획득 | 17M → ~1M | **약 6.71x 감소** |

**그런데 통제 A/B (stock vs patched, 동일조건 bitrate sweep): 두 곡선 noise 내 완전 일치.** knee·plateau 동일, 어느 offered rate에서도 throughput·loss 차이 없음.

**Interpretation (a):** producer enqueue lock을 6.7배 줄여도 throughput 0 변화 → **producer lock은 병목이 아니었다.** 회계 정합(UdpInDatagrams+UdpRcvbufErrors=datagram) 확인, correctness 버그 없음.

---

## Slide 4 — ★ 부수 발견: 우리 baseline이 IP fragment하고 있었다

(a) datagram 크기별 GRO 머지·throughput (CX5, DIM on, receiver):

| `-l` | GRO 머지 | throughput | 비고 |
|---|---|---|---|
| 8000 | 7.9 | 28.0 G | non-frag |
| **8972** (=MTU−28) | 6.8 | 27.8 G | **non-frag 상한** |
| **9000 (기존 baseline)** | **2.0** | **17 G** | **9000>8972 → IP fragment** |

- (a) **GRO 머지 factor ≈ min(64, 65536 / datagram_size)** — 64KB super-skb 한도. SW GRO knob(flush/batch) 불변, datagram 크기가 결정.
- (a) **`-l 9000`은 fragment 구간** → 머지 2로 붕괴 + throughput 최악. **non-frag `-l 8972`에선 DIM on ≈ off (~30G)로 "DIM 폭락"이 상당 부분 사라짐.**

→ 기존 "UDP DIM ON 폭락" 서사에 **fragmentation 교란**이 섞여 있었음. 이후 baseline을 `-l 8972`로 교정.

---

## Slide 5 — Plan B: consumer batch recvmsg (patch 0004) — 소형에서만 효과

- 신규 `UDP_RECV_BATCH` 소켓옵션(105) + `udp_recvmsg_batch`: recvmsg 1회로 reader_queue에서 **여러 datagram 연속 drain** (TCP `tcp_recvmsg_locked` 식). 입증: recvmsg당 8972→~750K바이트(~90 datagram), syscall 100x↓.
- (a) 효과 (경량 sink, 포화):

| datagram | PLAIN | BATCH | 효과 |
|---|---|---|---|
| 8972B (대형) | ~50 G | ~50 G | **없음** (syscall 100x↓해도) |
| 1472B (소형) | 20.6 G | 24.8 G | **+21%** |

- (a) 크기 sweep cross-over: batch 이득은 **hump** — ≤512B(pps-bound) ~0%, **peak ~2KB +31%**, ≥6KB(copy-bound) ~0%.

**Interpretation:** consumer syscall batch도 **syscall-bound 소형 구간에서만** 도움. 대형(8972B)은 copy-bound라 무효 → **consumer 병목도 syscall이 아니다.**

---

## Slide 6 — ★ 진단 정정: 진짜 비용은 "재분해"

lock·syscall batch 둘 다 대형에서 무효 → 비용은 다른 데 있다.

| | TCP | UDP |
|---|---|---|
| GRO super-skb(~64KB) | **안 쪼갬** (byte stream) | **`udp_rcv_segment`로 N개 datagram 재분해** (`udp.c:2190`) |
| socket 큐 | super-skb 1개 | datagram N개 skb |
| recvmsg copy | 64KB **1번** | datagram당 **N번** |
| per-skb 스택 처리 (csum/filter/enqueue/dequeue/alloc·free) | 64KB당 **1번** | **N번** |

(b) **진짜 per-datagram 비용 = per-skb 스택 통과 + copy setup.** UDP는 GRO로 합친 걸 **도로 쪼개서** N번 치름. lock·syscall은 곁가지였다. TCP가 빠른 건 64KB 단위 처리.

(a) 측정 증거: `rx-gro-list` on + UDP_GRO off일 때 `rcv_skb`(super-skb) 471K → `one_skb`(분해 후) 3.27M = **약 7배 재분해**.

---

## Slide 7 — ★ 진짜 fix: UDP_GRO (재분해 방지)

처리 단위 차이 (왜 빠른가):

| 처리 방식 | 단위 | recvmsg당 bytes |
|---|---|---|
| PLAIN / BATCH recvmsg | skb **N**, copy **N**, 스택 **N** (재분해) | 8972 / ~763K |
| **UDP_GRO** | **skb 1, copy 1, 스택 1** (재분해 X) | **~61KB (~7 datagram)** |

(a) 효과 — **진짜 단일코어**(NIC IRQ+consumer 모두 core1, `set_irq_affinity one 1`), DIM on, -l 62804:

| | UDP_GRO **off** | UDP_GRO **on** |
|---|---|---|
| goodput | 28.6 G (loss 95%) | **43 G** (loss ~50%) |

→ **+51%.** 포화된 단일코어에선 softirq 재분해 제거가 더 결정적(이전 2코어 측정 +33%보다 큼).

`UDP_GRO` 소켓옵션 → `ACCEPT_L4` 설정 → `udp_unexpected_gso`=false → **재분해 안 함** → super-skb 통째로 1 recvmsg(+`gso_size` cmsg). **lock·syscall이 아닌 "재분해 제거"가 진짜 lever.** (커널 이미 지원 — 우리 patch는 사실 불필요했다.)

---

## Slide 8 — BIG UDP 시도: IPv4 64KB 천장

- super-skb를 64KB 넘게 키우려 `gso/gro_max_size`를 netlink로 512K까지 올림 → **머지 불변(~64KB)**.
- (a) 원인: IPv4 UDP GSO **송신이 64KB로 고정**(IP cork; BIG TCP는 TCP송신 전용). sender가 >64KB contiguous 버스트를 못 만들고 receiver GRO가 그걸 못 넘음.
- → **BIG UDP(>64KB unit)는 IPv4에서 구조적으로 막힘.** 64KB unit이 단일코어 천장. 그 위는 multi-core 또는 IPv6 jumbogram.

---

## Slide 9 — iperf3 완전판: GSO(TX) + GRO(RX) + 정확한 loss 회계

문제: iperf3는 UDP_GRO 미사용 + GSO 시 loss 통계가 깨짐(블록당 헤더 1개).
수정(`iperf_udp.c`, 양쪽 배포):
- **TX**: GSO 활성 시 **각 gso_size segment마다 헤더(seqno 증가)** → 각 wire datagram이 자기완결적 iperf 패킷 → loss 정확 (GRO 유무 무관).
- **RX**: `UDP_GRO` 기본 ON, recvmsg 1회로 super-skb drain → `gso_size`로 split·회계.

(a) 검증 (양쪽 완전판, -l 62804=7×8972): sender 79.6G / **8,870,225 datagram** / receiver 42.8G / **4,097,820 lost (46%)** / jitter 0.001ms — **sender total == receiver total, 회계 정합.** (이전 `1e+02%`/거대 jitter 해소.)

---

## Slide 10 — 커널 패치는 GSO+GRO에서 무용 (3-way A/B)

(a) 동일 complete iperf3, GSO+GRO, **config·컴파일러 동일**(diff=0, gcc 9.4.0), 커널만 변경:

| 커널 | 평균 |
|---|---|
| stock 6.6.9 | ~45.9 G |
| vanilla (무패치, 동일 빌드) | ~46.1 G |
| **patched (-udpbatch)** | **~46.3 G** |

**세 커널 동일.** (이유) UDP_GRO가 재분해를 없애 → producer batch 미진입 + iperf3는 UDP_RECV_BATCH 미사용 → consumer batch 미진입 → **패치가 구조적으로 우회됨.**
(교훈) 첫 측정에서 patched가 59.7G로 튀었으나 재측정 시 46G로 수렴 — **reboot A/B 첫 arm은 반드시 재측정.**

---

## Slide 11 — ★ UDP vs TCP (진짜 단일코어): GSO+GRO로 동급, DIM은 무관

⚠️ **방법론 2중 교정:**
- 단일코어 = NIC IRQ까지 core1 핀 (`set_irq_affinity one 1`). 검증: mpstat CPU1 **idle 0.99%, softirq 51%+sys 45% (포화)**.
- "DIM on vs off"도 무의미했음 — `dim.sh off-pure`=rx-usecs 50, **adaptive도 부하중 50으로 수렴** → 둘 다 50 비교였음.

(a) 진짜 단일코어, GSO+GRO, -l 62804, -b 0:
- **UDP ≈ TCP ≈ ~44G** — 동급 도달 (UDP가 TCP를 넘지는 않음).
- **코얼레싱(rx-usecs) sweep**: 0 / 8 / 50 / 200 / 1000 / adaptive 전부 **~41–46G, loss ~50%** → **DIM/코얼레싱 무관.**
  (GRO가 64KB 단위로 per-packet 비용 흡수 → 인터럽트 빈도가 throughput을 안 바꿈.)

→ 원래 **"UDP DIM ON 폭락(4.8 vs 19.4G)"은 DIM이 아니라** fragmentation(-l 9000) + no-GSO/GRO + 핀 실수의 복합 artifact. 제대로 잡으면 **DIM은 non-factor, UDP는 TCP와 동급.**
⚠️ (정정) 이전 "UDP 68G > TCP 61G / DIM off가 lever"는 softirq가 별도 코어에 있던 2코어 artifact.

---

## Slide 12 — 종합 결론 & 다음

**investigation arc (negative result로 진단을 정정해온 과정):**
1. lock batch(producer) → 6.7x↓, throughput 무변화 ⇒ lock 병목 아님
2. syscall batch(consumer) → 소형만 +31% ⇒ syscall 병목 아님
3. 진단 정정 ⇒ 비용은 **per-skb 재분해(스택+copy)**
4. **UDP_GRO(재분해 방지)** = 진짜 fix (**진짜 단일코어 +51%**)
5. iperf3 완전판(GSO+GRO+정확 loss) 구현·배포
6. 커널 패치는 GSO+GRO에서 무용 (3-way A/B)
7. **진짜 단일코어**(NIC IRQ까지 핀)에서 **UDP ≈ TCP ≈ 44G** — GSO+GRO로 동급 도달. **UDP_GRO가 lever, lock·DIM·RX스티어링은 아님.**

**정정된 thesis:** UDP가 본질적으로 느린 게 아니다 — ① baseline의 fragmentation 실수(-l 9000), ② iperf3가 UDP_GRO 미사용·재분해 경로. **GSO+GRO로 재분해를 없애면 단일코어 UDP가 TCP와 동급(~44G)에 도달.** lock·DIM은 lever가 아니었다.

**방법론 교훈:** 단일코어 UDP RX 측정은 consumer뿐 아니라 **NIC IRQ까지 `set_irq_affinity one N`으로 핀**해야 한다 (아니면 softirq가 딴 코어로 새서 ~2코어 측정이 됨).

**다음 (남은 lever):** 단일코어 ~44G가 천장(CPU1 포화: softirq 51%+sys 45%). **multi-queue/multi-flow 병렬화로 line rate(100G)** 시도. (또는 IPv6 jumbogram으로 >64KB unit.)

---

## 부록 A. 산출물

| 종류 | 경로 |
|---|---|
| patch (producer) | `reports/patches/0003-udp-batch-enqueue-gro-segments.patch` |
| patch (producer+consumer) | `reports/patches/0004-udp-producer-batch-and-consumer-batched-recvmsg.patch` |
| 완전판 iperf3 (GSO+GRO+loss) | `~/iperf3-source/src/iperf_udp.c` (sslab3·sslab4 배포), 정본 `~/lab/tools/iperf_udp.c.sslab4` |
| 도구 | `tools/udp_sink.c`(plain/batch/gro), `udp_blast.c`(GSO sender), `set_netdev_maxsize.c`(netlink) |
| 커널 (sslab4) | `6.6.9`(stock), `6.6.9-udpbatch`(patch), `6.6.9-vanilla`(control) |
| 데이터 | `logs/{ab_sweep_*, consumer_ab_*, dgram_sweep_crossover, udp_gro_the_real_fix, bigudp_summary, iperf3_complete_gso_gro, kernel_ab_summary, dim_off_udp_beats_tcp}.txt` |

## 부록 B. Q&A 예상

- **Q. 그럼 우리가 만든 커널 패치는 의미 없나?** lock/syscall이 병목이 아님을 **반증**하는 데 필수였다(negative result). 다만 throughput fix로는 UDP_GRO가 답이고 커널 수정 불필요.
- **Q. -l 9000을 계속 썼으면?** fragmentation으로 머지 2·throughput 17G에 갇혀 진짜 그림을 못 봤을 것. baseline 교정이 분기점.
- **Q. UDP_GRO 켜면 그냥 끝 아닌가?** 받는 앱이 setsockopt(UDP_GRO)+gso_size cmsg 처리해야 함(코드 수정). iperf3는 그냥 못 켬 → 우리가 개조.
- **Q. DIM이 진짜 lever 아닌가?** 진짜 단일코어 + GSO+GRO에선 rx-usecs sweep(0~1000) 전부 ~42G로 **DIM 무관**. ("DIM on vs off" 비교 자체도 둘 다 rx-usecs 50이라 무의미했음.) 원래 "DIM 폭락"은 fragmentation + no-GRO + 핀실수 artifact.
- **Q. 44G가 천장인가?** 진짜 단일코어(CPU1 포화: softirq 51%+sys 45%) 천장. 그 위는 multi-queue/multi-flow 병렬화.
- **Q. 단일코어 핀 어떻게?** consumer는 `taskset -c 1`, NIC IRQ는 `sudo ~/ice-1.16.3/scripts/set_irq_affinity one 1 ens81f0np0`(+irqbalance off). 둘 다 해야 진짜 단일코어.
