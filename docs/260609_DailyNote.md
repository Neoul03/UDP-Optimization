# 260609 Daily Note — SoftRoCE vs HW RoCE vs TCP/UDP single-flow 매트릭스

## 목표
single-flow only. RoCE TX/RX 4조합(soft→soft, soft→HW, HW→soft, HW→HW) + 동일 NIC 바닐라 TCP/UDP를 측정해 Gbps 표로 정리.

## 환경 / 방법론
- NIC: ens81f0np0 = CX5 (mlx5), 100Gbps, MTU 9000 (양쪽). sslab3=192.168.11.120, sslab4=192.168.11.238.
- **single flow**: RoCE = `ib_send_bw -q 1 -s 65536 -D 5` (client=TX, server=RX). TCP/UDP = `iperf3` 1 stream.
- pinning: 양 끝 프로세스 `taskset -c 1`. (NIC IRQ는 기본; sslab4는 spread-rxe-irqs 영구 적용 상태.)
- soft = patched rxe(`/usr/src/.../rdma_rxe.ko`), **zcopy=0** (=page_pool baseline = best soft TX; 어제 zcopy는 −12~21% regression이라 제외).
- RoCE IB MTU = 4096 (HW가 4096 강제; soft↔soft도 stock RX쪽 4096 cap → 전 cell 4096 통일).
- TCP/UDP는 netdev MTU 9000 사용(IB MTU와 별개) → RoCE와 직접 같은 조건 아님(주석).
- 호스트 상태 정의: SOFT = mlx5_ib 제거 + rxe0 link / HW = mlx5_ib 적재 + rocep23s0f0 active.
- GID: soft rxe0 RoCEv2 = idx 1, HW rocep23s0f0 RoCEv2 = idx 3.

## 결과 (Gbps, single-flow)

### ⚠️ 두 가지 측정 방식 — "proc만 pin" vs "진짜 원코어"
처음 매트릭스는 **proc taskset core1 + NIC IRQ는 spread(기본)** 였다. mpstat로 확인한 결과 이건 **원코어가 아님**:
- soft RX(HW→soft) 측정 중 sslab4: **core1 100%(perftest busy-poll) + core5 100%(커널 NAPI+rxe RX)** = **2코어 점유**. spread IRQ라 단일 flow의 RX softirq가 RSS로 core5에 떨어지고, busy-poll은 core1. 즉 soft RoCE RX는 2코어 쓰고 있었음.
- HW RoCE: CPU는 busy-poll(core1)뿐, 패킷은 NIC(ASIC). "1코어"지만 그 100%는 **실제 처리 아니라 polling**.

→ `set_irq_affinity one 1 ens81f0np0`(ice script, msi_irqs fallback로 mlx5 IRQ도 잡음) 으로 **24개 comp-IRQ 전부 core1**에 고정 + irqbalance stop + proc도 core1. mpstat 재확인: **core1만 100%, 나머지 0** = 진짜 원코어.

### RoCE 매트릭스 (Gbps) — `ib_send_bw -q1 -s65536`
| TX \ RX | soft RX | HW RX |
|---|---|---|
| **[A] proc-pin only (IRQ spread, 사실상 2코어)** | | |
| soft TX | 16.4 | 25.5 |
| HW TX | 16.8 | 93.5 |
| **[B] 진짜 원코어 (IRQ+proc 전부 core1)** | | |
| **soft TX** | **12.1** (soft→soft) | **25.9** (soft→HW) |
| **HW TX** | **9.2** (HW→soft) | **93.5** (HW→HW) |

- raw [B]: soft→soft 1512 MB/s, soft→HW 3234, HW→soft 1143, HW→HW 11687 MB/s.

### ⚠️⚠️ [B]조차 원코어 아니었음 — rxe_wq(unbound workqueue) 누락
[B](IRQ+proc core1)로도 **soft TX은 여전히 2코어**였다. mpstat(soft→HW, sslab3 TX): **core1 100%(busy-poll) + core8 87%** = rxe **requester가 다른 코어**에서 돈다.
- 원인: `rxe_task.c:13 alloc_workqueue("rxe_wq", WQ_UNBOUND, ...)` — rxe req/resp/comp task가 **unbound workqueue kworker**. NIC IRQ 핀은 NAPI/RX-softirq만 잡지 이 WQ는 안 잡음. WQ_SYSFS 없어 per-WQ cpumask도 없음.
- 해결: **global unbound WQ cpumask** `/sys/devices/virtual/workqueue/cpumask = 0x2`(core1)로 모든 unbound WQ를 core1에. 재확인 mpstat: TX·RX 양쪽 **core1만 100%** = 진짜 원코어.

### [C] 진짜진짜 원코어 (IRQ + proc + **unbound-WQ** 전부 core1) ← 최종
| TX \ RX | soft RX | HW RX |
|---|---|---|
| **soft TX** | **13.5** (soft→soft) | **22.0** (soft→HW) |
| **HW TX** | **9.2** (HW→soft) | **93.5** (HW→HW) |

- **soft→HW 25.9→22.0** (−15%): requester가 쓰던 2번째 코어를 뺏으니 하락 = soft TX도 사실 2코어 썼던 것.
- HW→soft 9.2 불변(RX responder는 NAPI와 같은 core1서 이미 돌고 있었음 — queue_work가 NAPI코어=core1에 떨어짐). soft→soft 13.5(noise대 12.1, 둘 다 core1-only). HW→HW 93.5 불변(rxe 안 씀).
- **결론: 진짜 원코어 soft RoCE 천장 — RX bound ~9G(HW→soft), soft↔soft ~13G, soft TX bound ~22G.** TCP/UDP(42.7/17.0)는 rxe_wq 안 쓰므로 [B]가 이미 진짜 원코어였음(검증됨).

### 바닐라 TCP/UDP — `iperf3` 1 stream, netdev MTU 9000, **진짜 원코어**(IRQ+proc core1, NIC GSO/GRO on)
TCP/UDP는 rxe_wq 안 쓰므로 IRQ+proc core1이면 이미 진짜 원코어(mpstat core1-only 확인).

**중요: -b0(무제한)는 GSO sender가 81G로 RX를 압도 → NIC ring drop으로 RX CPU 낭비 → goodput 붕괴(ON 10.9G).** 공정비교는 **rate sweep으로 RX 지속가능 천장**을 본다.

**UDP app GSO+GRO 비교 (rate sweep, recv goodput / loss)**
| -b 오퍼 | **ON** (GSO `-l65000` + GRO=1) | **OFF** (`-l8972`, GRO=0) |
|---|---|---|
| 10G | 10.0 (0%) | 10.0 (0%) |
| 15G | — | 15.0 (0%) |
| 20G | 19.4 (3%) | 20.7 (5%) |
| 28G | 24.8 (16%) | — |
| 30G | **26.7 (14%)** ← 천장 | 18.4 (38% 붕괴) |
| 35G | 17.0 (51% 붕괴) | — |

- **UDP 원코어 RX 지속가능 천장: ON ≈ 26.7G / OFF ≈ 20.7G → app GSO+GRO가 +~28%.** 단 저rate(≤20G, 무손실)에선 둘 다 비슷 — GSO/GRO 이득은 **고부하에서 천장을 높이고 붕괴를 늦추는 것**(OFF는 -b20 넘으면 붕괴, ON은 -b30까지 버팀).
- mpstat: ON -b32 중 sslab4 **core1만(74%)** = 진짜 원코어 확인.

### ★ 핵심: UDP "≈TCP 44G"는 원코어가 아니라 2코어였다
"예전 UDP GSO+GRO가 TCP급(44G)"의 정체 규명. UDP GSO+GRO ON, NIC GSO/GRO on, `-l65000`(GSO 확실히 작동, sender 81G):
| 배치 | -b40 결과 | 천장 | mpstat |
|---|---|---|---|
| **1코어** (NAPI+consumer 모두 core1) | — | **~27G** | c1만 74% |
| **2코어** (NAPI=core1, consumer=core3) | **40.0G (0% loss)** | **~40G** | c1:37%(NAPI/GRO) + c3:73%(consumer copy) |

- **결론**: 예전 ~44G는 **NAPI softirq와 iperf3 consumer가 서로 다른 코어**에 떨어진 2코어 결과였다(iperf3 기본 동작 — IRQ만 pin하면 consumer는 스케줄러가 딴 코어에 둠). 이번엔 `taskset -c 1`로 **둘을 같은 코어에 강제** → NAPI(GRO+stack)와 consumer(recvmsg copy)가 직렬화 → 27G.
- `-l` 문제 아님(65000=64KB, GSO 정상 작동 확인).
- **시사점**: 원코어에서 **TCP(42G) > UDP(27G)**. UDP는 2번째 코어를 줘야(40G) TCP를 따라잡음. **TCP RX가 per-byte 단일코어 효율이 더 좋다**(TCP GRO가 64KB super-skb로 강하게 coalesce → recvmsg/copy당 바이트 多; UDP GRO는 SW frag-list라 coalesce 약함). 즉 "UDP≈TCP"는 코어 1개 더 쓴 비교였음.

### "예전 UDP 44G" 재현 안 된 이유 규명 (스크린샷 대조)
과거 로그(UDP RX 44G ≈ TCP)가 지금 27G로 안 나오던 이유 = **측정 방식 차이 2개**:
1. **(주범) NIC IRQ pinning.** 내 "진짜 원코어"는 `set_irq_affinity one 1`로 **IRQ까지 core1** → NAPI softirq + consumer가 같은 코어 직렬화 → 27G(sweep)/~10G(-b0). 과거 로그는 `-A1`/taskset으로 **프로세스만** core1, **IRQ는 spread** → NAPI는 RSS로 딴 코어 → 실질 2코어 → 44G. (htop엔 core1만 100%로 보였지만 NAPI는 다른 코어서 돌고 있었음.)
   - 증명: IRQ spread하자 RX **9.77→28.6G**, mpstat에 NAPI 2번째 코어(c16:86%) 등장.
2. **(부주범) `-Z`(zerocopy TX).** 송신 -Z가 sender를 매끄럽게 해 RX GRO coalescing↑. 동일 2코어 config에서 `-l65000 -Z`=40G(0%) vs `-l65000` no-Z=29G(26%). 내 측정은 -Z 미사용.
- 2코어 UDP는 GRO coalescing/스케줄 운에 28~40G로 **flaky**(44G는 좋은 쪽 끝, cross-NUMA면 28G). NUMA: node0=0-11, node1=12-23.
- **결론**: 내 표의 "UDP 원코어 27G"도 맞고, 과거 "44G"도 맞다 — **쓴 코어 수가 다름**(+ -Z). 진짜 원코어면 UDP는 27G가 천장.

### ★ 완성 표 — single-flow, **진짜 원코어**(IRQ+proc[+rxe_wq] = core1), NIC GSO/GRO on
| 프로토콜 / 구성 | Gbps |
|---|---|
| RoCE **soft→soft** | **13.5** |
| RoCE **soft→HW** | **22.0** |
| RoCE **HW→soft** | **9.2** |
| RoCE **HW→HW** | **93.5** |
| **TCP** | **42** (stock iperf3; modified build은 ~36) |
| **UDP** app GSO+GRO **ON** | **~27** (26.7 천장) |
| **UDP** app GSO+GRO **OFF** | **~21** (20.7 천장) |

- 측정: RoCE=`ib_send_bw -q1 -s64K`(IB MTU4096), TCP/UDP=`iperf3` 1-stream(netdev MTU9000). 전부 IRQ core1+proc core1, soft RoCE는 unbound-WQ도 core1.
- 해석: 원코어 RX 효율 **HW RoCE(93G, ASIC) >> TCP(42G) > UDP-GSO/GRO(27G) > UDP-plain(21G) ≈ soft-RoCE-TX(22G) > soft-RoCE-RX(9~13G)**. soft RoCE RX가 원코어에서 제일 약함(per-packet ICRC검증+reassembly+MR copy+completion 직렬).

- TCP는 원코어로도 42.7G(거의 안 떨어짐 — TCP RX가 per-packet 효율적). UDP는 원코어 17.0G(NAPI+consumer 1코어 직렬화). UDP를 2코어(NAPI core1/consumer core3)로 풀면 34.2G까지.

### ★★ 왜 원코어 UDP(~25G) < TCP(42G)? — 근본원인 규명 (perf 기반, 앞선 추측 정정)
> 정정: 위 79·87줄의 "UDP GRO가 TCP보다 coalesce 약해서 per-byte 비쌈" 가설은 **틀렸다**. 아래가 검증된 답.

**(1) GRO 진짜 켜짐 확인.** strace로 `setsockopt(5, SOL_UDP, UDP_GRO, [1], 4)=0` 확인. 커널이 re-segment 안 하고 coalesced super-skb 전달. (modified iperf3 `iperf_udp.c:615`서 env `IPERF3_UDP_GRO` 조건 호출.)

**(2) per-byte 비용은 TCP=UDP.** 동일 20G paced에서 perf(`-C 1`):
| | core1 busy | top func |
|---|---|---|
| TCP @20G | 58% | copyout 35% |
| UDP @20G | 57% | copyout 36% |
→ 거의 동일. **UDP가 본질적으로 무거운 게 아니다.** 둘 다 copy-bound.

**(3) 차이는 천장 근처 = flow control.** 
- UDP 무손실 천장 ~22-25G인데 그때 **core1 60%밖에 안 씀**(CPU 포화 아님!). 
- UDP `-b40` overrun시: core1 **100%**, but copyout 35%→27%로 줄고 **clear_page_erms 18% + alloc/free churn ~12%** 가 코어 잡아먹음 = **버릴 패킷의 버퍼 alloc/zeroing/free 낭비**. → goodput **13G로 붕괴**(b22 22G보다 *나쁨*).
- TCP `-b40` = 35.9G 정상(천장 42G까지 스케일).

**(4) 결정적 — TX pacing으론 안 된다.** `-b40G` paced → UDP 13G(66% loss). `-b22G`→22G(0%). **UDP는 backpressure가 없어 수신 용량(~25G) 초과해 쏘면 cap이 아니라 붕괴.** TCP의 window가 송신자를 수신 능력에 묶어주는 일을 UDP는 못 함.

**(5) -l(버스트) 줄이기 테스트 → 효과 없음.** 버스트 1~7 datagram/sendmsg(-l 8972~62804) 전부 무손실 천장 **~25-28G로 평평**. → GSO 순간버스트가 주범 아님. 진짜 한계는 **1코어에서 NAPI(ring 비우기)가 consumer(copy)와 시분할** → consumer 도는 동안 ring 채워짐 → flooding(backpressure 없음)이면 ~25G에서 overflow. TCP는 window로 ring을 절대 안 넘치게 함 → CPU 한계(42G)까지.

**결론(정정):** UDP per-byte 비용 = TCP. UDP가 원코어에서 느린 진짜 이유 = **flow control 부재**. flooding이 1코어 NAPI-starved 구간에 RX ring을 넘쳐 ~25G에서 drop+churn. TCP window는 송신자를 수신능력에 self-clock → 무손실로 42G. → 2코어(NAPI 전용)면 ring을 빨리 비워 UDP도 40G. **(governor 확인: 부하시 core1 3.3GHz max, confound 아님.)**

### ★★★ 정확한 bottleneck 위치 — 카운터로 확정 (-b35 overrun, 35G제공/15.9G수신/53%loss)
| 드롭 위치 | 5초간 delta |
|---|---|
| NIC ring (`ethtool -S rx_out_of_buffer`) | **27,004** |
| **socket buffer (`nstat UdpRcvbufErrors`)** | **204,385** (7.5×) |

core1 100% 내역 (mpstat): **%soft=53%(NAPI) + %sys=46%(consumer recvmsg+copyout)**.

**확정된 인과**: NAPI가 53% 받아서 **NIC ring은 거의 다 비운다(드롭 27K뿐)** → 패킷이 소켓까지 도달. 그런데 **consumer는 46%밖에 못 받아 socket 수신버퍼를 못 비움 → 거기서 204K 드롭(UdpRcvbufErrors)**. 즉:
- **드롭 지점 = socket receive buffer** (NIC ring 아님).
- **병목 = consumer(recvmsg+copyout)의 CPU 굶주림** — 1코어에서 NAPI(softirq)와 시분할하느라 ~46%만 받음.
- lossless(-b28, core 64%)일 땐 consumer가 따라가나, overrun되면 NAPI 부하↑가 consumer를 더 굶겨 socket overflow→붕괴(vicious cycle).
- 이래서 2코어(NAPI 전용)가 답: consumer가 코어 통째로 받아 socket 비움→40G. TCP는 window로 overrun 자체를 막아 NAPI 부담↓+socket overflow 0 →1코어 42G.

### NAPI 튜닝(gro_flush_timeout + napi_defer_hard_irqs) — 모디스트 +12%, 천장 못 뚫음
`/sys/class/net/ens81f0np0/{napi_defer_hard_irqs,gro_flush_timeout}` 조합 스윕(둘 다 nonzero라야 deferral 작동):
| 설정 | 무손실 천장 | 붕괴점 |
|---|---|---|
| baseline (0/0) | ~25G | ~30G |
| **defer=2, timeout=200us** | **~28G** | ~32G |
| defer=2, timeout=20us | ~26G | ~32G |
| defer=8, timeout=200us | ~25G (악화) | ~30G |

- **defer=2/200us가 최적 → 25→28G (+12%).** defer=8은 과해서 악화. NAPI를 덜 자주·큰 배치로 돌려 IRQ오버헤드↓·GRO배치↑.
- **그러나 한계 못 뚫음**: 튜닝 -b28에서도 **core1 64%** (여전히 CPU 포화 아님). -b0 blast는 **10.2G로 baseline(10.0G)과 동일** = deferral이 blost overrun을 못 막음.
- 이유: deferral은 IRQ오버헤드·coalescing만 개선하지 **backpressure를 못 만든다**. flooding이면 ring은 여전히 넘침. TCP의 window 같은 송신측 제어가 없는 한 1코어 UDP는 ~28G가 현실적 천장(2코어 필요 또는 app-level pacing).
- (테스트 후 knob 0/0으로 원복.)

## Interpretation (b, 구조적)
1. **soft RX(~16G)가 soft TX(~25G)보다 더 센 병목.** soft→soft·HW→soft 둘 다 ~16-17G로 동률 = **TX 종류 무관, soft RX가 천장**. RX가 per-packet 더 무겁다(ICRC 검증+reassembly+MR copy+completion). soft→HW(25.5G)는 soft TX가 천장(HW RX는 공짜).
2. **HW→soft는 붕괴 안 함(16.8G).** 어제 memory의 "HW TX→soft RX = go-back-N 0.84G 붕괴"는 **재현 안 됨** — `ib_send_bw -q1`(RC, RQ 크레딧)에서는 soft RX 속도로 self-limit. 0.84G는 다른 tool/MTU/load였을 가능성(→ memory 정정 필요).
3. **HW→HW 93.5G** = 라인레이트 근접(single QP -q1, -s64K, core1 pin이라 98G 대비 약간 낮음).
4. **TCP 44.4G > UDP 20.9~34.2G single-flow.** UDP는 RX가 **CPU-bound**(rmem 512MB로 올려도 동일 21G → 버퍼 아님). NAPI와 consumer를 **다른 코어로 분리**하면 21→34G(2코어 사용). TCP RX는 per-packet 더 효율적이라 1프로세스 코어로도 44G. ※주의: 어제 memory의 "UDP≈TCP≈44G"는 본 측정서 미재현(21~34G) → IRQ/코어 배치·GRO 실효성 재검토 필요.

## Limitation
- RoCE IB MTU 4096 vs TCP/UDP netdev MTU 9000 → 직접 동일조건 아님(packet 크기 다름). RoCE soft RX가 MTU8192면 더 오를 여지(soft↔soft 한정).
- UDP single-flow 수치는 IRQ/consumer 코어 배치에 매우 민감(20.9~34.2G). "default(spread IRQ, 1프로세스)" 와 "NAPI|consumer 분리" 두 값 병기.
- pinning은 프로세스 taskset 위주. NIC IRQ 단일코어 강제(0x2)는 consumer와 충돌해 오히려 UDP 악화(69% loss) → single-flow는 NAPI/consumer 분리가 유리.

## Next validation step
- soft RX가 진짜 천장이므로 **soft RX 쪽 per-packet 비용 분해**(perf on sslab4 RX core: ICRC_check / reassembly / MR copy / skb free 비중)가 다음 타겟. soft→soft에서 16G를 올리려면 RX를 건드려야(지금까지 패치는 전부 TX측).
- UDP 44G 재현 조건 규명(어제 memory와 불일치).
- (옵션) soft↔soft MTU8192로 soft RX 천장 재측정.

## 측정 raw 로그
- soft→HW: `65536 153200 3191.66 MB/s`
- soft→soft: `65536 98200 2045.85`
- HW→HW: `65536 561000 11687.51`; sslab3 HW gid3=192.168.11.120 RoCEv2
- HW→soft: `65536 101000 2104.19`
- TCP: `25.9 GB / 44.4 Gbits/sec, 0 retr`
- UDP default: sender 41.3G / receiver 20.9G (49% loss, rmem 208KB)
- UDP rmem512MB: receiver 21.4G (48%) — 버퍼 아님 확정
- UDP IRQ→core1+consumer core3: receiver 34.2G (17% loss)

## 상태 (true-single-core 매트릭스 측정 종료 후)
- **양쪽 HW** (sslab3·sslab4 = mlx5_ib 적재, rocep23s0f0 ACTIVE, rxe 미적재). HW→HW cell 직후.
- **NIC IRQ = core1 고정** (양쪽 `set_irq_affinity one 1 ens81f0np0`, 24 comp-IRQ→0x2). **irqbalance STOP**(양쪽), **spread-rxe-irqs STOP**(sslab4). 단일코어 측정 유지하려면 이대로.
- rmem_max 512MB(sslab4). bench 프로세스 0.
- 원복: IRQ 원상 = `sudo systemctl start irqbalance` + (sslab4) `start spread-rxe-irqs`. soft 측정 시 = 해당 호스트 `rmmod mlx5_ib; insmod .../rdma_rxe.ko; rdma link add rxe0 ...; set_irq_affinity one 1`(IRQ 재고정), zcopy=0.
- ⚠️ soft↔HW 전환 시: **반드시 rxe0 link 먼저 제거(또는 rmmod rdma_rxe) 후 modprobe mlx5_ib** — rxe가 포트/UDP4791 점유 중이면 mlx5_ib 로드 실패(같은 포트 공존 불가).

## ★★★ 커널 A/B: udpbatch(lock+socket-copy patch) vs stock — 진짜 원코어 (NULL 결과)
질문: "lock+socket-layer 비효율 고친 6.6.9-udpbatch(patch 0003 producer lock-batch + 0004 consumer batched-recvmsg)가 진짜 원코어에서 이득 있나?"

**방법**: sslab4 receiver를 stock 6.6.9 ↔ 6.6.9-udpbatch 리부팅 A/B. 동일 셋업 강제(MTU9000, rmem512M, governor performance, IRQ core1(set_irq_affinity one 1), irqbalance off, GRO+gro_list on). sender=sslab3 stock 고정. iperf3+GSO/GRO, -l65000. stock×3(리부팅 전후) + udpbatch×3 arm, 각 sweep x2.

**결과 — 차이 없음 (GRO-ON, -b30 무손실점)**:
| arm | -b30 goodput |
|---|---|
| stock arm1/2 | 29.5 / 29.5 G @0% |
| udpbatch arm1/2/3 | 28.6~30.0 G @0~2% |
| stock arm3(post-reboot) | 27~29 G |
→ 전부 ~28-30G@0%로 noise 내 동일. -b0 blast도 stock 9.7G ≈ udpbatch 10.7G. GRO-OFF도 둘 다 ~22-25G. **udpbatch 이득 0.**

**patch는 실제로 engage함 (중요)**: udpbatch에서 GRO-off(re-segment) 시 bpftrace —
- `udp_queue_rcv_one_skb`(datagram) = 2,219,428
- `__udp_enqueue_schedule_skb`(per-skb lock) = **2,709 (0.12%)**
→ producer lock-batch가 **lock을 99.9% amortize**(260605의 6.7x 재확인). **그런데도 throughput 무변화** = "patch는 작동하나 도움 안 됨"을 진짜 원코어에서 재확인.

**드롭 위치 (양 커널 동일)**: -b35서 `UdpRcvbufErrors`(socket) 1.7~2.5M vs `rx_out_of_buffer`(NIC ring) 9~29K = **socket buffer 드롭이 ~85x 지배**. 커널 바꿔도 동일.

### 결론 — "amortization 문제 아직도 발생하나?"
- **lock amortization**: udpbatch가 해결(99.9%↓). 하지만 **원래 병목 아님** → throughput 0 변화.
- **copy amortization**: GRO가 이미 해결(64KB super-skb 1 copy).
- **남은 진짜 병목 = consumer copyout이 NAPI와 1코어 시분할로 굶주려 socket buffer overflow**. 이건 lock도 syscall도 아니라 (a)raw copy 비용 (b)single-core NAPI/consumer 경합 (c)flow control 부재. **udpbatch 패치(lock+consumer-syscall-batch)는 이 셋 중 어느 것도 안 건드림** → 무용. (게다가 consumer-batch는 iperf3가 UDP_RECV_BATCH 미사용이라 미engage이고, 260605대로 대형 datagram=copy-bound에선 batch 효과도 0.)
- **∴ 진짜 원코어에서도 udpbatch는 이득 없음.** 1코어 천장(~30G)을 올리려면 패치가 아니라 NAPI 분리(2코어) / flow control / zero-copy recv 같은 구조 변경 필요.

## ★★★ 정정: 원코어 천장은 copy가 아니라 ~25G 하드리밋 (zero-copy도 못 뚫음)
udp_blast(GSO flood) → udp_sink 매트릭스, **IRQ core1 검증(mpstat c1-only)**, max blast 드레인율:
| sink 모드 | 1-core | 2-core(sink c3) |
|---|---|---|
| GRO-off (plain recvmsg) | 9.5G | 25.5G |
| GRO-on (copy) | 11.3G | 24.4G |
| **NO-COPY (MSG_TRUNC)** | **25.5G** | **81.3G** |

**⚠️ 앞서 "zero-copy 원코어 80G" 는 IRQ drift artifact였다(정정).** 재검증(IRQ core1, mpstat c1만 100%): no-copy **원코어 = 25.5G**, 80G는 **2코어** 필요.

**결론 (사용자 Q2 맞음):**
- **원코어 RX 하드리밋 ≈ 25G** — NAPI+GRO+dequeue가 한 코어를 포화시키는 지점. copy 유무 무관(no-copy도 25G에서 c1 100%).
- **copy의 역할 = flood collapse 유발**: with-copy flood 11G vs no-copy 25G. copy가 느려서 overrun→collapse. no-copy는 25G까지 안 무너짐. 하지만 **천장 자체(25G)는 안 올림**.
- pacing: collapse만 회피(~25-30G 도달), 천장 안 올림. zero-copy: flood collapse만 회피(11→25), 천장 안 올림.
- **→ 원코어에선 pacing도 zero-copy도 ~25-30G 못 뚫는다. 2번째 코어(NAPI 분리)만이 뚫음**(no-copy 2코어 81G / GRO-on 2코어 controlled 40G).

**Q1 (app-GRO off + 2코어 → TCP 근접?) — 못 감 (사용자 맞음):**
- GRO-on 2코어 controlled(-b40) = 40G ≈ TCP. 
- GRO-off 2코어 = ~28G (iperf3 -b0서 consumer c3:100%). re-segment로 consumer가 per-datagram recvmsg → 더 일찍 포화.
- → **app-GRO(re-segment 제거)가 있어야 2코어가 TCP급(40G). 없으면 2코어라도 ~28G.** GRO가 필수 enabler, 2코어만으론 부족.

### 최종 종합 (UDP 원코어 한계의 진짜 구조)
- **원코어 RX 하드리밋 ~25-30G**: copy/lock/syscall 다 줄여도(zero-copy 포함) 못 뚫음 — NAPI+GRO+dequeue가 한 코어 포화.
- copy는 flood에서 collapse 유발(추가 페널티). flow control(또는 pacing)로 collapse 회피 가능하나 천장은 그대로.
- **천장 돌파 = 2코어(NAPI 분리)뿐**, 그리고 그게 TCP급(40G) 되려면 **app-GRO(re-segment 제거) 필수**.
- TCP가 1코어 42G인 건: window로 collapse 없고 + copy가 contiguous(효율적) + ... 그래도 UDP 원코어 한계(~25-30G)보다 높음 = TCP RX 경로가 per-byte 약간 더 효율적 + flow control.

## 2코어 코어별 CPU + TCP 2코어 (사용자 질문)
**Q1: 2코어에서 IRQ는 다른 코어가? 2번째 코어도 CPU 많이 쓰나?** — 예, 둘 다 그렇다.
UDP 2-core (NAPI=IRQ core1, consumer sink core3), flood:
- **core1 (IRQ/NAPI): 83% busy, soft(softirq) 82%** ← IRQ/NAPI 처리는 별도 코어(core1).
- **core3 (consumer): 100% busy, sys 100%** ← 2번째 코어 완전 포화(recvmsg+copy). **copy가 병목**.

**Q2: TCP를 2코어로 쓰면 성능 많이 오르나?** — 아니, **+12%뿐**(UDP보다 훨씬 적음).
| TCP | goodput | core1(NAPI) | core3(consumer) |
|---|---|---|---|
| 1-core (둘 다 core1) | 43.4G | 100% (soft27+sys73) | — |
| 2-core (NAPI c1 / server c3) | **48.5G** | 32% | **100% (sys)** |

- TCP 2코어 = +12% (43→48.5). UDP 2코어는 +48%(27→40). **차이 이유**: TCP 1코어는 flow control로 이미 깔끔하게 43G(붕괴 없음) → 2번째 코어는 NAPI/consumer 경합만 약간 풀어줘 +12%. UDP 1코어는 경합/붕괴로 hobbled(27G) → 2코어가 그걸 풀어 +48%.
- **공통**: 2코어에선 consumer 코어가 **100% 포화(copy-bound)** = 새 병목. TCP 48.5 > UDP 40 (TCP copy가 약간 더 효율 + overrun 없음). 더 올리려면 consumer도 분산(multi-flow/multi-core) 또는 zero-copy.

## Tier 0 구현 결과: CONFIG_HARDENED_USERCOPY=n → +5% (양쪽)
6.6.9-nohardened 빌드(HARDENED off, 나머지 동일), 리부팅 A/B, **진짜 단일코어**.
| | stock(on) | nohardened(off) | Δ |
|---|---|---|---|
| TCP 1-core | ~40.4G | ~42.5G | +5% |
| UDP 1-core(lossless) | ~28G | ~29-30G | +5-7% |
- perf상 `check_object_size` 11%였으나 throughput 이득은 ~5% (per-frag bounds check만 제거, bulk copyout은 불변). kallsyms `__check_object_size`=0 확인, no-copy(mode3)는 불변(80.8G) = copy path 한정.
- 예상대로 **양쪽 다 +5%, UDP-TCP 갭은 안 닫힘**(Tier1이 닫음).

### ★★ 치명적 교훈: irqbalance가 리부팅마다 IRQ 재분산 → "단일코어"가 2코어로 오염
- 리부팅 후 `set_irq_affinity one 1` 해도 **irqbalance가 (재시작되어) IRQ를 24코어로 다시 spread** → 단일 flow NAPI가 RSS 코어로, consumer는 core1 = **실질 2코어**. 증상: TCP "단일코어"가 34~59G로 2배 출렁(RSS 코어 placement 운).
- **해결: `sudo systemctl mask irqbalance`** (stop만으론 부족, mask해야 재시작 안 함; mask는 리부팅에도 persist). 그 후 `set_irq_affinity one 1`. mpstat/IRQ dist로 매번 검증 필수.
- ⚠️ 이전 세션들의 단일코어 측정 중 일부는 이 오염 가능성 — IRQ dist 검증 안 한 건 재확인 필요.

### 빌드 함정 재확인 (260605와 동일)
- `make modules_install`을 `INSTALL_MOD_STRIP=1` 없이 → unstripped 모듈 → initrd 1.4GB → **부팅 hang**. (sslab4 IPMI 리셋 필요했음.)
- 고침: `make modules_install INSTALL_MOD_STRIP=1` + `update-initramfs -u -k <ver>` → initrd 142MB 정상.

## ★★★★ 치명적 방법론 발견 2개 (Tier0/1b 측정 재해석)

### (1) IRQ 핀 GAP — "단일코어"가 사실 2코어였다 (재발)
- `set_irq_affinity one 1`이 **comp IRQ 1개를 ffffff(all-cores)로 남김** → 단일 flow가 그 RSS 큐를 쓰면 **NAPI가 random 코어로 float**(예: core12). consumer는 core1, NAPI는 core12 = 실질 2코어. mpstat에서 **core1 %soft=0** 으로 발각.
- **해결: msi_irqs 전부 수동으로 `echo 2`** (25개 다 core1) → mpstat에서 core1에 %soft+%sys 둘 다 = 진짜 단일코어. **매 측정 %soft가 core1에 있는지 검증 필수.**
- ⚠️ **이번 세션의 Tier0 A/B, UDP single-core 수치 다수가 이 contamination 영향** — 재측정 필요.

### (2) single-flow UDP는 OVERRUN-bound이지 CPU-bound 아니다
- 진짜 단일코어 MAX_HEAD=64: -b28서 core1 **53%**(sys30+soft20), -b30서 55%, 무손실 천장 ~28-30G인데 **그때 core 안 포화**(overrun으로 collapse가 CPU 포화보다 먼저). -b34+서야 100%(collapse 처리하느라).
- ⇒ **single-flow UDP 천장(~28-30G)은 overrun이 정함, CPU 효율 아님.** 그래서 **Tier0(HARDENED)·Tier1b(MAX_HEAD) 같은 CPU 최적화는 single-flow 천장을 안 올린다**(노이즈만). 효과를 보려면 **CPU-bound 영역**에서 재야:
  - (a) **고정 무손실 rate에서 CPU% 측정**(낮을수록 최적화 성공) — deterministic.
  - (b) **consumer-bound 2코어**(consumer core 100% copy) 또는 **multi-flow**(CPU 포화).
- 즉 Tier0 "+5%"도, Tier1b "ceiling↑"도 single-flow 천장으론 신뢰 측정 불가 — 메트릭 자체가 틀렸음.

### 올바른 메트릭 (앞으로)
1. IRQ: msi_irqs 전부 수동 core1 핀 + mpstat %soft 검증.
2. CPU 최적화 효과 = **고정 lossless rate(-b25 등)에서 core1 busy%** (64 vs 256, HARDENED on/off). 낮을수록 이득.
3. 또는 consumer-bound 2코어 / multi-flow goodput.
- 1 data point 확보: 진짜 단일코어 MAX_HEAD=64 @ -b28 = core1 **53%**. (256 baseline은 리부팅 필요.)

## ★ Tier 1b 최종 결과 (MLX5E_RX_MAX_HEAD 256→64) + 신뢰 측정법 확립
### 신뢰 측정법 (드디어): combined=1 + fixed-rate CPU%
- mlx5 IRQ는 24큐 RSS라 single flow의 NAPI 코어가 4-tuple hash로 정해짐 → smp_affinity 핀해도 재분산되거나 다른 큐로 빠짐(managed-ish). **`ethtool -L ens81f0np0 combined 1`(RX큐 1개)** 로 RSS 자체를 없애야 NAPI가 결정론적으로 core1. mpstat에서 core1에 %soft+%sys 둘 다 = 검증.
- single-flow UDP 천장은 overrun-bound라 CPU 최적화가 천장에 안 보임 → **메트릭 = 고정 무손실 rate(-b25/-b28)에서 core1 busy%** (낮을수록 CPU 효율↑). combined=1로 분산 ±1-2%p로 안정.

### A/B (nohardened, combined=1, true single-core, 4 samples)
| rate | MAX_HEAD=256 | MAX_HEAD=64 | Δ |
|---|---|---|---|
| -b25 | ~49% busy | ~46.5% | **-6%** |
| -b28 | ~58% busy | ~53% | **-8%** |
- **MLX5E_RX_MAX_HEAD 256→64 = core1 CPU ~6-8%↓** (datagram당 copy-break 256→64B = double-copy 192B/pkt 절감; 7 datagram/super-skb면 ~1.3KB/62KB). 진짜·재현 가능한 이득.
- 단 **single-flow 천장(~28-30G)은 안 오름**(overrun-bound). 이 CPU 절감은 **CPU-bound 영역(multi-flow / consumer-bound 2코어)** 에서 throughput으로 전환됨.
- Tier0(HARDENED off, copy path -11% perf-time)와 **stack 가능**(독립적 — Tier0=copyout bounds-check, Tier1b=head copy-break).

### 종합 (Tier0+1b)
- 둘 다 **CPU 효율 최적화**(throughput 천장 아님). single-flow는 overrun-bound라 천장 불변, 그러나 CPU-bound 시나리오선 Tier0(~5%)+Tier1b(~6-8%) ≈ **~12% CPU 절감** 기대.
- "UDP=TCP" 갭(per-byte 1.5x)을 닫으려면 이 CPU 절감들 + 진짜 copy 제거(Tier2 zero-copy)가 필요. Tier0/1b만으론 갭 부분적.

## ★★★ Tier 2 (B): AF_XDP zero-copy receiver — copyout 제거 = 단일코어 ~84-89G
zero-copy recv를 실제 구현(`tools/af_xdp_sink.c`, libbpf xsk). NIC이 umem에 직접 DMA, 패킷 descriptor만 읽고 **payload copy 안 함**. MTU1500(jumbo AF_XDP는 frame≥16384 unaligned/multibuf 필요 — 별도), 1472B datagram, udp_blast flood, **진짜 단일코어 core1**.

| 수신 방식 | goodput | core1 |
|---|---|---|
| **AF_XDP ZEROCOPY** (copy 0, stack bypass) | **~84-89G** | 81%(soft63+sys13+usr4) — 미포화! |
| AF_XDP COPY (zc=0, 커널이 umem에 copy, stack는 여전히 bypass) | **64.6G** | |
| socket recvmsg (udp_sink, full stack+GRO+copy) | **flood서 0.2G 붕괴** (지속가능 ~20-30G) | |

### 결론 (B 성공)
1. **zero-copy 자체 효과 = +30~37%** (AF_XDP ZC 88.8 vs COPY 64.6). frame copy 제거.
2. **AF_XDP(bypass) vs socket = 변혁적**: 단일코어 ~84G vs socket 지속가능 ~20-30G(flood선 0.2G 붕괴) = **3~4배**. copyout(58-68%) + per-packet socket 오버헤드 + overrun collapse를 전부 없앰.
3. AF_XDP ZC가 core1 81%로 **미포화** → 더 올라갈 여지(라인레이트 100G 근접 가능). 이전 측정 no-copy(MSG_TRUNC) 81G와 일치 — copyout이 진짜 지배적 병목임을 실제 zero-copy로 재확인.

### 한계 / 성격
- **MTU1500** (jumbo는 AF_XDP frame≥16384 unaligned umem이 "Invalid argument"으로 실패 — mlx5 ZC가 frame≥MTU 요구. multibuf로 가능하나 별도 작업).
- AF_XDP는 **커널 UDP 스택+GRO 완전 우회**(raw ethernet frame). socket 앱의 drop-in 대체 아님 — 앱이 eth/ip/udp 파싱 + datagram 의미론 직접 처리해야. 즉 "UDP socket을 빠르게"가 아니라 "UDP를 우회하는 zero-copy 데이터플레인".
- 그래도 **"copy 제거하면 단일코어가 25-30G→84G"** 를 실측 증명 = 최적화 방향의 상한을 보여줌.

### 종합 (Tier0 → Tier2)
- Tier0(HARDENED off) +5%, Tier1b(MAX_HEAD) CPU -6~8% — socket 경로 안에서의 점진 개선(천장은 overrun-bound라 제한적).
- **Tier2(zero-copy/bypass) = 판을 바꿈** (~84G). socket UDP의 근본 한계(copy+per-packet+overrun)를 우회. "UDP를 TCP급 이상으로"의 진짜 답은 zero-copy 데이터플레인(AF_XDP/io_uring-zc)이지, socket 경로 미세최적화가 아님.
