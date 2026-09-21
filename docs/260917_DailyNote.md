# 260917 Daily Note — Phase 1: vanilla baseline 재확정 (텀프로젝트 시작)

## 목표
네트워크시스템설계 텀프로젝트용 baseline. 6.6.9-vanilla (stock, HARDENED=y)에서 확정 방법론으로 TCP/UDP × 1c/2c 매트릭스 재측정.

## 방법론 (260609 확정판 + 오늘 추가)
- sslab4 리부팅 → **6.6.9-vanilla** (grub-set-default, initrd 136M 검증 후. 부팅 ~240s 정상)
- irqbalance **masked**(persist 확인) + `ethtool -L ens81f0np0 combined 1` + **msi_irqs 25개 전부 core1**(000002 확인) + governor performance(전 코어) + rmem 512MB + NAPI knob 0/0
- **⚠️ 신규 함정: MTU가 리부팅 시 1500으로 리셋** — 1차 실행분 전체 무효(`_INVALID_mtu1500`). `baseline_matrix.sh`에 MTU 설정+assert 추가.
- 스크립트: `scripts/baseline_matrix.sh <tag> <reps>` — 매 점 mpstat c1/c3 %soft/%sys 검증, 카운터 delta 수집.
- 각 점 10s × 3 reps. TCP=stock iperf3, UDP=수정판(GSO+GRO). sender sslab3 taskset -c 1, no -Z.
- 로그: `logs/baseline_vanilla_20260917_171240/`

## 결과 (Gbps, receiver goodput, 3 reps)

| 구성 | lossless 천장 | reps | mpstat |
|---|---|---|---|
| TCP 1c | **35.6 / 37.1 / 41.6** (median 37) | | c1 soft~23+sys~57 ≈80% |
| TCP 2c | **48.8 / 51.6 / 58.5** (median 52) | | c3 sys 79 |
| UDP plain 1c (-l8972, GRO off) | **22.0 @0%** (b25부터 6-14% loss, goodput ~23) | 3/3 | c1 ~43% |
| UDP plain 2c | **28-30 @0%** | 3/3 | c3 sys ~40 |
| UDP GSO+GRO 1c | **30.8-32.0 @0%** (b32) | 2/3 완전 0%, r3 b30만 4.3% | c1 ~50-60% |
| UDP GSO+GRO 2c | **40 @0%** 확실, b45는 bistable(45@0% 1회 / ~31@31% 2회) | | c3 sys ~53 |
| UDP GSO+GRO 1c -b35 (overrun) | bistable: 35@0% 1회 / 17-21@39-51% 2회 | | |

### 드롭 위치 (overrun -b35, counter delta) (a)
- r1: UdpRcvbufErrors **+310,619** vs rx_out_of_buffer +16,821 → **18.5x socket 지배**
- r3: **+395,681** vs +26,326 → **15x socket 지배**
- → 260609의 "드롭 = socket buffer, NIC ring 아님" vanilla에서도 재확인.

### 이상 포인트
- r1/r2 `udp_plain_1c_b20` = 12.3G: **sender 자체가 12.3G만 송신** (sender line 동일) = TX측 flake. b22가 22G 정상이므로 수신 천장 결론에 영향 없음. r3는 20G 정상.

## Interpretation (b)
1. **vanilla 1c: TCP 37 vs UDP-GRO 32 vs UDP-plain 22** → 갭: plain은 TCP의 0.59, GRO는 0.86. GRO가 갭의 대부분을 닫고, 잔여 ~14%가 커널 최적화 타겟.
2. 260609 (nohardened) 수치 대비 TCP↓(42→37)·UDP↑(28→32) — 방향이 반대라 커널 차이만으로 설명 안 됨. **10s 단축 런 + bistable 유리쪽 샘플링** 가능성 (c). 30s 확인 런 필요.
3. bistable collapse (b35 1c, b45 2c) vanilla에서도 재현 — memory의 hysteresis와 일치 (a).
4. UDP 1c 천장(30-32G)에서 c1 ~50-60%만 사용 = **overrun-bound, CPU-bound 아님** 재확인 (a). CPU 최적화 효과는 fixed-rate CPU%로 재야 함.

## Limitation
- 10s/점은 bistable 판정에 짧다. 논문용 최종 수치는 30s×5 reps로 키 포인트 재확인 필요.
- TCP 1c 분산 큼(35.6~41.6). %usr 미수집(soft/sys만) — busy 총량 해석 주의.
- sender no -Z. -Z arm은 미포함(260609에서 +GRO coalescing 효과 확인됨).

## Next validation step
1. 키 포인트 30s 확인 런: tcp_1c, udp_gsogro_1c b30/b32, udp_gsogro_2c b40 (×5)
2. fixed-rate CPU% baseline: -b20/-b25에서 c1 busy% (Tier0/1b A/B용 메트릭)
3. perf 비용 분해 (Phase 2): vanilla에서 copyout/check_object_size/napi_alloc 비중
4. 이후 nohardened 리부팅 → 동일 매트릭스 = Tier0 arm

---

# Part 2 — 30s 확정 baseline + perf 분해 + autotune 구현 (텀프로젝트 Phase 2-3)

## 스코프 확정 (사용자 합의)
- **모든 실험 진짜 단일코어 고정** (IRQ+NAPI+consumer 전부 core1). 2코어는 참고선으로만.
- 구현 범위: **P3 rcvbuf autotune (필수) + P2 early drop (필수) + P1 transparent GRO (스트레치)**.

## 30s 확인 런 (vanilla, 3 reps) — 논문 baseline 확정치 (a)
`logs/confirm_vanilla30s_20260917_180740/`
| 구성 | Gbps | c1 busy |
|---|---|---|
| TCP 1c | 35.9/37.0/36.5 (**~36.5**) | **93%** (CPU 포화) |
| UDP plain 1c | **22 @0%** (b25→22-23@8-12%) | 49-53% |
| UDP GSO+GRO 1c | **30 @0%** 확실, 32 @0% 2/3 | 54-61% |
| UDP GSO+GRO b35 | 35 @0% **2/3** / 17.4@50% 1/3 (bistable) | 70-73% |

**★ per-byte 효율 (b→a급)**: TCP 2.55 %CPU/Gbps (93/36.5) vs UDP-GRO **1.91 %CPU/Gbps** (61/32). **UDP RX가 per-byte로는 TCP보다 싸다.** 못 올라가는 이유는 오직 overrun collapse. b35 유지 런은 c1 73%로 여유 → **overflow 관리만 되면 1코어 UDP > TCP(36.5) 가능** = 논문 핵심 thesis의 정량 근거.

## perf 비용 분해 (vanilla 1c, 동일 -b20) (a)
`logs/perf_breakdown_*/`
- copyout: TCP 33.8% ≈ plain 31.3% ≈ GRO 31.5% — per-byte 비용 동일 재확인, copy 지배.
- plain에만: `__nf_conntrack_find_get`+`__siphash_unaligned` ~2.3% (per-datagram conntrack lookup; GRO는 super-skb당 1회).
- `__check_object_size` 1.3-1.9%(전코어 기준), `mlx5e_add_skb_shared_info_frag` 3.5-4.7%.

## P3 구현: UDP rcvbuf autotune (patch 0006)
`reports/patches/0006-udp-rcvbuf-autotune.patch` (+90/-0, vanilla 기반)
- **설계**: TCP-DRS 유사하되 RTT 없는 UDP에 맞게 **occupancy 기반** — `__udp_enqueue_schedule_skb` 진입 시 `rmem > sk_rcvbuf/2`면 sk_rcvbuf 2배 성장(cap까지). SO_RCVBUF 설정 앱(`SOCK_RCVBUF_LOCK`)은 불변. udp_mem 글로벌 한도는 기존 `udp_rmem_schedule`이 그대로 보호.
- sysctl: `net.ipv4.udp_rmem_autotune`(default 1) / `udp_rmem_autotune_max`(default 32MB). **runtime 토글 → 리부팅 없는 A/B**.
- 파일: `net/ipv4/udp.c`(helper+call+init), `net/ipv4/sysctl_net_ipv4.c`, `include/net/netns/ipv4.h`.
- 빌드: sslab4 `~/kbuild/linux-6.6.9` (vanilla 트리 in-place, `.vanilla-orig` 백업, LOCALVERSION=-autotune)
- A/B 계획: `scripts/ab_autotune_1c.sh` — A(off+208K stock) / B(off+512M 수동) / C(on cap512M+208K) / D(on cap32M+208K), `ss -uampi`로 rb 성장 실측. 성공 기준: C≈B, A=기존 stock, D가 deployable default로 얼마나 회복하나.

## P2 설계 초안 (early drop) — 다음 빌드 사이클 (c, 구현 전)
- **관찰 근거**: collapse 시 NAPI %soft 22→48%로 폭증(버릴 패킷 처리)하며 consumer를 굶김. 드롭 자체는 enqueue 시점(풀 스택 통과 후).
- **설계 v1**: `udp_queue_rcv_skb()` 초입(재분해/checksum 전)에서 `sk_rmem_alloc > sk_rcvbuf`면 (super-)skb 통째 drop + UdpRcvbufErrors 회계. GRO super-skb면 1 체크로 7 datagram 분량의 재분해+checksum+enqueue 시도 절약. sysctl `net.ipv4.udp_early_drop` 토글.
- **설계 v2 (스트레치)**: socket full 시 NAPI deferral 힌트 → ring을 HW에서 넘치게 (rx_out_of_buffer 드롭은 CPU 0) = "NIC까지 backpressure". cross-layer라 v1 검증 후.
- 예측: overrun(-b35+)에서 goodput이 17G 붕괴 대신 ~30G cap, NAPI %soft 감소. autotune(성장)과 상보적: autotune이 burst 흡수, early drop이 지속 초과분을 싸게 폐기.

## ★★★ P3 autotune A/B 결과 (6.6.9-autotune, 진짜 1c, 15s×2 reps) (a)
`logs/ab_autotune_20260917_183753/`
| arm | gsogro b24-32 | plain b20/22 | plain b25(overrun) | 실측 rb (ss) |
|---|---|---|---|---|
| A stock 208K | 10.5-28G @0-59% (erratic) | **5.3-6.3G @71-75%** | 6.1 @75% | 212992 |
| B 수동 512M | 전부 0% (32G까지) | 20/22 @0% | 23 @3.8-5.4% | 512M |
| **C autotune cap512M** | **전부 0% = B** | **= B** | 23 @4-6% = B | **1.7-6.8MB** |
| D autotune cap32M | 전부 0% = B | = B | 22.8 @8.9% | ≤33M |

- **C ≡ B**: 208KB default에서 자동 성장으로 수동 512MB 성능 완전 회복. plain b22 **6.0→22G (3.7x)**.
- **메모리 ~100x 절약**: steady state rb 1.7-6.8MB로 충분 (수동은 512M 상시).
- D(패치 기본값 32M cap)도 lossless 전 구간 커버 → deployable default 성립.
- 한계 (P2 동기): 지속 overrun(plain b25)선 cap까지 성장 + r≈480MB 상주 backlog(bufferbloat) + loss 4-6% 잔존 — 버퍼는 지속 초과분을 못 고침.
- stock(A) loss 0-59% erratic (동일 rate 재현마다 다름) = bistable 추가 증거.

## P2 early drop 구현 (patch 0007) → 6.6.9-udprx1
- `udp_queue_rcv_skb()` 초입에서 `sk_rmem_alloc > sk_rcvbuf`면 (super-)skb 통째 drop — 재분해/checksum/enqueue 시도 전. gso_segs만큼 RcvbufErrors/InErrors/sk_drops 회계 미러. encap 소켓 제외. `net.ipv4.udp_early_drop` (default 0).
- 6.6.9-udprx1 = autotune(0006) + early_drop(0007), 모두 runtime 토글.
- A/B: `scripts/ab_earlydrop_1c.sh` — E0(P3만)/E1(P3+P2)/F0(stock)/F1(P2만) × {gsogro b30/35/40/blast, plain b22/25/30}. 예측: E1이 overrun에서 collapse 없이 ~천장 cap 유지, F1은 stock 73% loss 완화.

## ★ P2 early drop v1 (socket-layer) A/B 결과 — NULL (a)
`logs/ab_earlydrop_*/` (6.6.9-udprx1, 1c, 15s×2)
| 비교 | 결과 |
|---|---|
| E0 vs E1 (autotune-on, gsogro b35/b40/blast) | 24.5/24.2, 22.3/22.8, 9.9/9.5 — **차이 없음** |
| E0 vs E1 (plain b25) | 4.6-9% vs 6.8-8.6% loss — noise 내 |
| F0 vs F1 (stock 208K) | bistable noise 지배 (r1 b40 +29% vs r1 b35 −20%, r2 혼재) — **일관 이득 없음** |
- 부수: E1 r1 plain에서 rb 3.4M 유지(bufferbloat 억제) 관찰됐으나 r2는 512M 도달 — **비결정적** (autotune 성장 vs ED race).
- **결론 (0003/0004와 같은 패턴의 교훈): socket layer는 shed 지점으로 너무 늦다.** udp_queue_rcv_skb 시점엔 skb build(15%)+alloc(17%)+GRO+스택 비용이 이미 지불됨. blast에서 %soft 52 불변이 증거.
- ⚠️ 측정 인프라: sslab3 sender가 간헐적으로 ~29.4G에 캡되는 flake 3회 관찰 (51.3GB/15s 시그니처) — 해당 샘플 무효 처리. 원인 추적 필요 (c).

## → P2 v2: driver-level RX shed (patch 0008, 6.6.9-udprx2)
- UDP enqueue overflow 시 `udp_rx_shed_mark(sk)`가 해당 소켓의 RX queue(`sk_rx_queue_get`)에 **200us shed window** 스탬프 (self-clocking: overflow 지속 시 갱신).
- mlx5 `mlx5e_handle_rx_cqe{,_mpwrq}`가 skb build **전에** window 검사 → CQE만 소비하고 WQE recycle (skb alloc/GRO/스택 전부 회피, `!skb` 경로와 동일한 안전한 recycle).
- per-queue cacheline-aligned 슬롯 256개. sysctl `net.ipv4.udp_rx_shed` (default 0). 한계: 같은 RX queue의 타 flow도 shed (combined=1 실험에선 동일; 논문에 명시).
- 예측: blast 9.5G@88% → NAPI 낭비 제거로 goodput ~25-30G 회복.

## ★★★★ P2 v2 driver-level RX shed A/B 결과 — 성공 (a)
`logs/ab_shed_*/` (6.6.9-udprx2, 1c, autotune on cap512M + rmem_default 208K 공통, 15s×2)

| 포인트 | G0 (P3만) | G1 (ED+shed) | G2 (**shed 단독**) |
|---|---|---|---|
| gsogro b35 | 24.0/24.4 @30-31% | 35.0@**0%** / 26.2@24% | 35.0@**0%** / 26.4@24% |
| gsogro b40 | 21.8-22.0 @44-45% | 25.0@37% (r2 flake) | 25.0/25.0 @37% |
| gsogro **blast(82G)** | **9.5-10.2 @86-88%** | **16.7 @79%** | **16.7-16.8 @79%** |
| blast mpstat | soft 51-52 / sys 34-35 | soft 26-28 / **sys 58-60** | 동일 |
| plain b25/b28 | 23.4-24.5 @5-16% | ≈G0 | ≈G0 |

1. **blast +65~76% (9.5-10.2 → 16.7-16.8G), 4/4 재현.** %soft 반감 + consumer sys 배증 = "버릴 패킷을 CQE에서 0비용 폐기 → consumer에 CPU 반환" 메커니즘 그대로 실증.
2. b40 지속초과: +14% (22.0→25.0).
3. b35 (bistable 경계): shed가 bad-state 바닥을 24→26 올리고, 2/4 런은 good state(35G@0%) 유지. bistability 완전 제거는 아님 (b) — window 200us 튜닝/이력 개선 여지.
4. **G1 ≡ G2**: socket-layer ED(v1)는 불필요. enqueue-failure 마킹만으로 충분 — 최종 설계는 v2 단독.
5. plain 경로 무변화(경계 과부하라 shed 발화 적음), lossless 구간 회귀 없음.
- ⚠️ sender 29.4G 캡 flake 계속 간헐 발생(오늘 5회) — 해당 샘플 무효 처리. 원인 미상 (c), 내일 추적.

### 오늘의 결론 (논문 뼈대 완성)
- **P3 autotune**: 기본값에서 수동튜닝 성능 완전 회복 (plain 6→22G), 메모리 1/100.
- **P2**: socket-layer는 늦다(NULL) → **driver-level shed가 답** (blast +76%). "드롭은 스택 위가 아니라 아래로 내려야 싸진다" — 0003/0004 lock 교훈과 대칭인 스토리.
- 남은 것: collapse curve 전체 sweep (goodput vs offered, 3 arms — 논문 Fig), 30s 확정 런, transparent GRO(P1, 스트레치), sender flake 추적.

## ★★★★★ 논문 Figure: collapse curve 3-arm sweep (a)
`logs/collapse_curve_20260917_195127/curve.csv` → `reports/fig_collapse_curve.csv` (1c, gsogro -l65000, 12s×2, flake 샘플 제외 평균)

| offered (G) | S0 stock | S1 +autotune | S2 +autotune+shed |
|---|---|---|---|
| 24 | 16.7 (30%) | **24.0 (0%)** | **24.0 (0%)** |
| 28 | 11.1 (59%) | **28.0 (0%)** | **28.0 (0%)** |
| 32 | 13.3 (58%) | **32.0 (0%)** | 29.4 (0%)* |
| 36 | 16.1 (54%) | 30.4 (15%) | 31.0 (14%) |
| 40 | 17.2 (57%) | 22.1 (44%) | **25.4 (36%)** |
| 50 | 17.2 (65%) | 18.1 (63%) | **22.6 (54%)** |
| 60 | 14.9 (75%) | 16.1 (72%) | **20.8 (65%)** |
| 82 (blast) | 8.7 (90%) | 9.5 (88%) | **16.9 (79%)** |
(*32G S2는 sender flake 2/2로 tx 29.4 — 값 자체는 무손실)

### 두 기법의 역할 분리가 그래프로 증명됨 (a)
- **autotune = 천장을 올린다**: lossless 24→32-36G. 그러나 **지속 과부하에선 stock과 동급** (50/60/blast에서 S1≈S0) — 버퍼는 초과분을 못 고침.
- **shed = 천장 너머를 지킨다**: 천장은 안 올리지만 과부하 영역 전체에서 +15~78% (blast 9.5→16.9G, **+78%**).
- **peak 대비 blast 유지율**: S0 36% / S1 26% / **S2 47%** — S1은 천장이 높아진 만큼 붕괴 폭도 커져 유지율이 오히려 최악. **autotune 단독 배포는 위험, shed와 세트여야 한다**는 정량 근거.
- stock(S0)은 24G에서도 이미 30-59% loss로 bistable — "기본값 리눅스 UDP는 1코어 25G를 못 넘긴다".

### 남은 과제 (내일)
1. 30s 확정 런으로 curve 재측정 (논문 최종 Fig), 3 reps.
2. b36 근처 bistability: shed window(200us) 튜닝 / 히스테리시스 도입.
3. **sender 29.4G 캡 flake** (오늘 7회, tx=29.4 시그니처) 원인 추적 — sslab3 TX측. 측정 신뢰도 이슈.
4. P1 transparent GRO (스트레치), Tier0/1b 재확정.

## ★★★★★ 정밀 천장 sweep (수정판, 30s×3, 1G 단위) — "천장"이 아니라 "안정성 경계"였다 (a)
`logs/ceiling_fine_*/` (autotune on + shed on, rmem_default 208K, 1c, gsogro)

| offered | 무손실 성공 | good state busy | bad state |
|---|---|---|---|
| 32G | **3/3** | 62-65% | — |
| 33G | **3/3** | 58-66% | — |
| 34G | 1/3 | 68% | 26.3-26.7G @21-22%, busy 91-92% |
| 35G | 0/3 | — | 25.6-26.0G @25-27%, busy 92-93% |
| 36G | 1/3 | **77%** | 25.6G @28%, busy 93% |
| 37G | **2/3** | **76-79%** | 25.6G @31%, busy 93% |

### ★ 핵심 재해석 (a→b)
1. **비단조(non-monotonic)**: 35G는 0/3 실패인데 **37G는 2/3 성공**. 용량 한계라면 불가능한 패턴 → **단일 천장이 아니라 두 개의 안정 상태(bistable)**.
2. **good state에서 코어가 안 포화**: 37G 무손실인데 busy **76-79%**. bad state는 92-93%로 CPU를 더 쓰면서 goodput은 26G. → bad state = **낭비가 자기유지되는 모드**(버릴 패킷 처리에 CPU 소모 → consumer 더 굶음).
3. **shed의 실제 효과 재정의**: bad state의 **바닥을 올린다** (이전 9-17G → 25.6-26.7G로 일정). 상태 진입 자체는 못 막음.
4. ⇒ **good state 용량 ≥37G로 TCP(36.5G)를 넘김.** 문제는 "얼마나 빠른가"가 아니라 **"good state에 들어가느냐"**.

### 논문에 미치는 영향
- "UDP 단일코어 천장 = 32G" → **"보장 무손실 33G, good state 용량 ≥37G (TCP 초과), 34-37G는 확률적"** 으로 서술 변경.
- 다음 레버는 처리량 최적화가 아니라 **상태 진입 제어**: shed window 히스테리시스(진입 임계 ≠ 해제 임계), 램프업 시 점진 개방, NAPI budget 연동.
- ⚠️ sender flake 이 sweep에서도 3회(tx 29.4/29.6/30.7) — b32/b33 저rate 구간 집중. 누적 10회, 내일 최우선 추적.

## ★★ bistability 메커니즘 추적 — GRO 붕괴 가설 반증, "큐 깊이" 확정 (a)
`logs/state_cost_*/` (bpftrace, good=b33 0%loss vs bad=b35 29%loss)
| 지표 | good | bad |
|---|---|---|
| recvmsg 반환 크기 분포 | [32K,64K) 1.13M회 지배 | [32K,64K) 0.94M회 지배 — **동일** |
| `skb_condense` / rcv_one | **0.00** | **0.96** |
| enqueue / rcv_one | 1.00 | 1.00 |

- **GRO merge factor는 두 상태에서 동일** → "압력 시 GRO가 열화돼 per-skb 비용↑" 가설 **반증**.
- `skb_condense` 0→0.96 = `rmem > sk_rcvbuf>>1`가 bad state에서 거의 항상 참 → **소켓 큐가 지속적으로 절반 이상 적체**.
- skb_condense 자체는 paged 60KB skb에서 즉시 return → 비용 원인 아님, **"큐가 깊다"는 표지**.
- ⇒ 같은 크기·같은 구조 데이터를 복사하는데 **바이트당 sys 비용만 2.2배** (1.32→2.85 %CPU/G).
- **새 가설 (c): 큐 깊이 → 캐시 지역성 파괴.** good은 enqueue 직후 dequeue(데이터가 L2/L3 상주) vs bad는 수백MB 적체 후 복사(DRAM-bound). 맞다면 **autotune이 양날의 검** — 버퍼를 키울수록 bad state가 더 비싸짐. collapse curve에서 S1(autotune)의 blast 유지율 26%로 최악이었던 것과 정합.
- 검증 중: ① perf cache-misses/IPC (good vs bad) ② `udp_rmem_autotune_max` 1M/4M/16M/512M 스윕 (캐시 가설이면 작은 cap이 과부하 goodput↑).
- ⚠️ bpftrace `sum(retval)`이 good state에서 비정상값(606TB) — histogram은 정상. sum은 신뢰 불가, bytes/call은 goodput÷recv_calls로 교차검증(good 52KB, bad 60KB).

## ★★★★★ bistability는 "startup 초기조건 민감성"이다 (a) — 결정적 증거
receiver 초당 interval (ceiling_fine 로그):
| t | bad run (b35) | good run (b37) |
|---|---|---|
| 0-1s | **24.9G, 18% loss** | 37.0G, **0%** |
| 1-2s | 27.5G, 21% | 37.0G, 0% |
| 9-10s | 25.7G, 27% | 37.0G, 0% |
| 최종 | 25.6G, 27% | 37.0G, 0% |
- **30초 내내 전이 0회.** 상태는 **첫 1초에 결정**되고 이후 각각 absorbing state.
- ⇒ 정상상태 요동이 아니라 **flow startup 초기조건 민감성**. 복귀 메커니즘 부재가 흡수성의 원인.
- 수동 512MB(vanilla)도 b35 2/3 성공에 그쳤음 → **큰 버퍼는 해법이 아니며 오히려 초기 적체를 무한 허용**(캐시 가설과 정합).

### good state vs TCP (a)
| | goodput | busy | 효율 |
|---|---|---|---|
| TCP (stock iperf3) | 36.5G | **93% 포화** | 0.39 G/%CPU |
| UDP good state (UDP_GRO on) | **37.0G** | 81-85% (여유) | **0.45 G/%CPU (+14%)** |
- **good state UDP는 TCP를 성능·효율 모두 앞섬.** 38-44G 구간 미시험. 단 UDP는 정확한 pacing + 운 좋은 진입이 전제 — "성능은 앞서고 제어가 없다".

### 다음 설계 (patch 0009 후보)
1. **깊이 제한(AQM)**: autotune cap을 메모리가 아닌 **캐시 기준**으로 (1-4MB). ← cap 스윕이 판정 중
2. **shed 히스테리시스**: 200us 창 → **low watermark까지 drain** (복귀 메커니즘 신설)
3. **startup guard**: 첫 구간 큐 얕게 강제 (현 autotune은 압력 후 반응형이라 startup에 늦음)
→ 목표: 37G가 운이 아니라 **보장**이 되게.

## ★★★★★★ 캐시 가설 확정 + 버퍼 크기 최적점 발견 (a) — 오늘 최대 성과
`logs/cache_cap_*/` (Xeon Silver 4310, L2 30MiB / **L3 36MiB**)

### ① perf 카운터: bad state = DRAM-bound (동일 offered 35G에서 상태만 다른 자연실험)
| 지표 | good (0% loss) ×3 | bad (25-26% loss) ×2 |
|---|---|---|
| **IPC** | 1.08-1.09 | **0.64** (−41%) |
| **cache-miss rate** | 17.4-17.6% | **44.1-44.2%** (2.5x) |
| **LLC-load-misses** | 58-66M | **205M** (3.1x) |
| 큐 적체 `r` | 0-294KB | **536MB (=rb 전체)** |
- r3의 b35는 good state로 떨어졌는데 **카운터도 good 그룹과 동일**(17.6%, IPC 1.08) → 카운터는 offered rate가 아니라 **state를 따라감**. 완벽한 대조군.
- ⇒ **"큐 깊이 → 캐시 지역성 파괴 → copyout이 DRAM-bound" 가설 확정.** 바이트당 비용 2배의 정체가 이것.

### ② autotune cap 스윕 — 버퍼는 클수록 나쁘다 (비단조 최적점)
| offered | cap 1M | cap 4M | cap 16M | cap 512M |
|---|---|---|---|---|
| 35G | 33.1-35.0 (0-5%) | 34.4 (1.8%) | ~30 (13%) | 35.0 (0%)* |
| 40G | 34.9 / **40.0 (0.04%)** | 34.0-34.3 (14%) | 29.3-29.6 (27%) | 24.7 (38%) |
| **blast 82G** | **25.2-25.4 (69%)**, busy **80%** | 22.7-22.9, busy 100% | 21.5-21.6, busy 100% | **16.5 (80%)**, busy 100% |
- **blast에서 cap 1M이 512M 대비 +53%** (16.5→25.3G), 2/2 재현. 게다가 busy 80%로 **포화조차 안 함**.
- b40에서 cap=1M이 **40.0G @0.04% loss** 기록 — **TCP(36.5G) 초과**, busy 88%.
- **비단조 최적점 존재**: 208KB(기본값)=너무 작아 GSO burst 못 흡수(6-11G 붕괴) → **~1MB=최적** → 16M/512M=캐시 파괴. L3 36MiB 대비 1M≪L3, 16M은 L3 절반 잠식.
- ⇒ **우리 패치의 기본 cap 32MB는 잘못된 선택.** 1-2MB로 변경해야 함.

### 설계 원칙 (논문 기여)
> **UDP rcvbuf autotune의 상한은 "메모리"가 아니라 "캐시" 기준으로 정해야 한다.**
> 버스트 흡수에 필요한 최소(수백KB~1MB)는 확보하되 LLC를 넘기면 안 된다. 기존 통념("버퍼는 클수록 안전")과 정반대.

---

# 260921 — 정적 rcvbuf 최적점 확정 (Phase A)
`logs/static_rcvbuf_*` (autotune OFF, 정적 rmem_default, shed ON, 1c, 15s×2, flake 재시도)

| buffer | b=35G rx/loss/busy | b=40G | blast 82G |
|---|---|---|---|
| **208K (리눅스 기본)** | 8.4 / 76% / 26% | 12.8 / 68% / 36% | **7.3 / 91% / 34%** |
| 384K | 13.3 / 62% / 32% | 18.5 / 54% / 46% | 15.3 / 81% / 53% |
| 512K | 23.8 / 32% / 54% | 23.6 / 41% / 54% | 15.6 / 81% / 55% |
| 768K | 29.6 / 16% / 66% | 28.4 / 29% / 65% | 22.5 / 72% / 74% |
| 1M | 34.0 / 2.8% / 74% | 37.1 / 7.1% / 84% | 25.4 / 69% / 80% |
| **1.5M ★** | 34.2 / 2.1% / 74% | **38.8 / 3.2% / 87%** | **32.3 / 61% / 99%** |
| 2M | 33.7 / 3.7% / 74% | 36.1 / 9.9% / 86% | 30.4 / 63% / 100% |
| 3M | 34.4 / 1.6% / 78% | 37.5 / 6.5% / 88% | 26.9 / 67% / 100% |
| 4M | 34.2 / 2.3% / 80% | 37.1 / 7.4% / 90% | 23.9 / 71% / 100% |
| 6M | 34.5 / 1.6% / 89% | 33.9 / 16% / 94% | 22.0 / 73% / 100% |
| 8M | 34.6 / 0.4% / 86% | 33.9 / 16% / 100% | 21.8 / 73% / 100% |

### 결론 (a) — 최적점 = 1.5MB, 재현성 ±0.5G
- **역U자 곡선 확정.** blast: 208K 7.3 → 1.5M **32.3** → 8M 21.8. 두 rep 전 구간 일치(±0.5G).
- **1.5M = L3(36MiB)의 1/24.** 기본값 대비 **4.4배**, 512MB 대비 **2배**.
- **1.5M만 busy 99%** (낭비 없이 포화). 그보다 크면 100% 쓰면서 goodput 하락 = 캐시 스래싱 순손실.
- 작은 쪽 실패 원인은 다름: 208K-512K는 busy가 26-55%로 **CPU가 남는데도** 못 받음 = 버스트 흡수 실패(shed가 과하게 발동).
- b=40에서도 1.5M이 38.8G@3.2%로 최고 — **TCP(36.5G) 초과**.
- ⇒ **패치 기본 cap 32MB는 확실히 잘못. 1.5MB로 변경 필요.**

---

# 260921 Part 2 — DIM이 bistability의 원인, 그리고 천장 47.9G

## Tier1 #1: threaded NAPI = 무효 (a)
`logs/threaded_napi_*` (1.5MB 고정, 3 reps)
| | b=35 | b=40 | blast |
|---|---|---|---|
| thrOFF shedOFF | 33.3/4.8% | 37.0/7.3% | 19.6/76% |
| thrON shedOFF | 34.5/1.4% | 37.1/7.3% | **19.2/77%** |
| thrOFF shedON | 34.7/0.7% | 37.2/6.7% | **33.0/60%** |
| thrON shedON | 33.8/3.5% | 36.2/9.1% | 33.0/60% |
- **threaded NAPI 단독으로 blast 19.2G = shed 없는 것과 동일.** shed만이 33.0G로 올림.
- 해석: threaded는 *누가* NAPI를 실행하는지만 바꿈. 단일코어에선 총 작업량 불변 → 버릴 패킷에 드는 헛수고 그대로. shed는 그 작업 자체를 제거.
- **논문 방어 확보**: "커널 기존 기능(threaded NAPI)은 이 문제를 못 고친다. 문제는 스케줄링 공정성이 아니라 낭비되는 작업량이다."

## Tier1 #2: TCP baseline 정정 + ★캐시 가설 TCP 교차검증 (a)
`logs/tcp_dim_rmem_*` (3 reps, 30s)
| arm | rx | IPC | busy |
|---|---|---|---|
| DIM on + 6MB | 35.9/40.4/40.4 (편차 큼) | 0.83-0.93 | 99-100% |
| **DIM off + 6MB** | **39.6/39.5/39.7 (±0.1)** | **0.94-0.96** | 100% |
| DIM on + 512MB | 33.5/32.9/34.9 | 0.75-0.78 | 100% |
| DIM off + 512MB | 36.5/33.6/38.3 | 0.79-0.92 | 100% |

1. **TCP baseline 36.5G → 39.6G 정정.** 기존 36.5는 시스템 iperf3 **3.19** 값. UDP와 같은 **3.20** 바이너리로 재면 39.6G(DIM off, ±0.1).
2. **★ 캐시 가설이 TCP에서도 재현**: tcp_rmem 6MB→512MB에서 39.3→33.8G(**−14%**), **IPC 0.94→0.77**. UDP(1.08→0.64)와 동일 패턴. ⇒ **"버퍼 키우면 캐시 붕괴로 느려진다"는 프로토콜 무관 일반 현상.** 논문 핵심 주장 대폭 강화.
3. DIM은 TCP에 해로움: 편차 ±2.3→±0.1, retr 1403-5925→811-1087.

## ★★★ 순서 재배치 → UDP × DIM: DIM이 bistability의 원인이었다 (a)
`logs/udp_dim_*` (1.5MB, 3 reps)
| 구성 | b=35 | b=40 | **b=43** | blast |
|---|---|---|---|---|
| DIM on + shed on | 35.0/0% | 37.1/7.1% | 40.2(39-43)/6.5% | 37.2/54% |
| DIM off + shed on | 34.1/2.5% | 38.0/5.0% | 38.9(39-39)/9.5% | **38.8/53%** |
| DIM on + shed off | 34.2/2.3% | 37.6/6.0% | 40.5(39-43)/5.9% | 30.1/63% |
| **DIM off + shed off** | 34.0/2.7% | 37.9/5.2% | **43.0(43-43)/0.0%** | 27.8/66% |

- **b=43에서 43.0G @0% loss 3/3 결정적** (개별 loss 0.0018/0.001/0.0045%), busy **87%**.
- 이전엔 42-43G가 2/3 확률 → **DIM off로 확률이 보장이 됨.**
- **해석**: DIM이 부하에 따라 인터럽트 주기를 동적 변경 → NAPI 배치 크기 요동 → flow 시작 시 큐 깊이 좌우 → state 진입 갈림. **DIM = 비결정성의 원천.**
- 프로젝트 출발점("DIM이 UDP를 죽인다")이 **다른 메커니즘으로 부활**: 처리량이 아니라 *결정성*을 해쳤다.
- shed 역할 최종 확정: **flood 전용**. b=43에선 shed on이 38.9로 오히려 손해(off 43.0). → 히스테리시스 필수.

## ★★★★ 천장 재탐색 (DIM off + shed off + 1.5MB) (a)
`logs/ceiling_dimoff_*` (3 reps, 30s)
| offered | 결과 | busy | eff |
|---|---|---|---|
| 44G | 38.4/38.4/39.8 @9-13% (**0/3**) | 86-87% | 0.45 |
| 46G | 39.1@15% / **46.0@0.098%** / **45.9@0.15%** (2/3) | 94% | 0.489 |
| **48G** | **47.9@0.29%** / 39.4@18% / **47.8@0.32%** (2/3) | **98%** | **0.489** |
| 50G | 39.8/43.3/45.3 @9-20% (0/3) | 95-100% | 0.42-0.45 |
| 52G | 41.8-42.4 @18-20% | 100% | 0.42 |

- **최고 기록: 47.9G @0.29% loss, busy 98%** = 사실상 CPU 완전 포화.
- **비단조 패턴 재확인**: 44G는 0/3 실패인데 46/48G는 2/3 성공. 40G 실패/43G 성공과 동일 현상. 특정 rate가 "나쁜 rate"임 (c) — 0.5G 단위 정밀 스윕으로 매핑 필요.

### 현재 최고 구성 vs TCP
| | UDP (DIM off, 1.5MB, shed off) | TCP (DIM off, 6MB) |
|---|---|---|
| goodput | **47.9G @0.29%** | 39.6G |
| busy | 98% | 100% |
| eff | **0.489** | 0.396 |
→ **처리량 +21%, 효율 +23%.** 세션 시작 시점(stock ~22-30G) 대비 2배 이상.

## Tier1 #3: GSO/GRO 귀속 정정 (a)
`logs/gso_gro_*` (1.5MB, DIM off, shed off, 3 reps)
- **GSO on + GRO off = 측정 불가**: sender 0% loss인데 receiver 87% loss. 수신 패킷수는 7,692,337/7,692,344 (실유실 7개). GSO가 65000B를 8972B×8로 쪼개면 **첫 조각만 iperf3 헤더 보유** → 7/8=87.5%를 유실로 오인. 도구 한계지 성능 결과 아님.
- **GSO off arm은 전부 sender-bound**: `-l 8972`면 단일코어 sender가 tx 33G에서 cap (loss 0%가 증거).
- **정정된 귀속**:
  - GSO = **송신측 레버** (없으면 33G cap, 수신측을 시험 못 함)
  - GRO = **수신측 CPU 레버**: 같은 33G에 busy **85%→65%** (−20%p, 바이트당 효율 +31%). b=25서도 70%→53% 동일 패턴
  - ⇒ 기존 "GSO+GRO 22→32G"는 귀속 오류. 처리량 상승 대부분은 sender가 더 보낼 수 있게 된 것.

## ★★★★★ Tier0+Tier1b (6.6.9-udprx3) — 예측 적중, 신기록 51.7G (a)
`6.6.9-udprx3` = udprx2 + `CONFIG_HARDENED_USERCOPY=n` + `MLX5E_RX_MAX_HEAD 256→64`
(`__check_object_size` 심볼 0개로 Tier0 적용 확인)

| offered | udprx2 busy | **udprx3 busy** | udprx2 goodput | **udprx3 goodput** |
|---|---|---|---|---|
| 43G | 87% | **80-81%** | 43.0 @0% ×3 | 42.9/40.4/43.0 |
| 46G | 90-94% | **86-87%** | 39.1@15%/46.0/45.9 (2/3) | **45.2/46.0/46.0 (3/3 무손실급)** |
| 48G | 93-98% | 89% | 47.9/39.4/47.8 (2/3) | 43.5@9.2% ×3 (**0/3**) |
| 50G | 95-100% | 93-95% | 39.8-45.3 @9-20% (0/3) | **49.9@0.24%** / 47.0 / 47.8 |
| 52G | 100% | 98-100% | 41.8-42.4 @18-20% | **51.7@0.5%** / 48.8 / 48.3 |

- **고정 rate CPU 절감 확인**: b=43에서 busy **87% → 80.7%** = **−7.2%p** (예측 5-8% 적중). 결정론적 지표라 가장 신뢰할 만함.
- **효율**: eff 0.42-0.49 → **0.48-0.54** (+7.5%)
- **신기록: 51.7G @0.5% loss, busy 98%.** TCP 39.6G 대비 **+31%**
- overrun-bound였던 과거엔 이 절감이 처리량에 안 나타났는데, **CPU-bound가 되자 그대로 전환**됨 — 260609의 "메트릭이 틀렸다"는 진단이 옳았음이 최종 확인.

### ⚠️ "나쁜 rate" 현상이 커널 구성에 따라 이동한다 (a)
- udprx2: 44G 0/3 실패, 46/48G 2/3 성공
- udprx3: **48G 0/3 실패**(43.5@9.2% ×3, 매우 일관), 46/50/52G 성공
- 나쁜 rate가 44→48로 **이동**. 단순 용량 한계가 아니라 **송신 pacing 버스트와 수신 처리 주기 간 공진(aliasing)** 가능성 (c).
- → 0.5G 단위 정밀 매핑 + rx-usecs 변경 시 나쁜 rate가 이동하는지 검증 필요.
