# UDP-Optimization

Linux UDP 수신 경로(RX)를 계측·분석하고, 커널을 수정해 단일코어 성능을 끌어올리는 프로젝트.

대학원 *네트워크시스템설계* 텀프로젝트. 100GbE ConnectX-5 환경에서 **진짜 단일코어**
(NIC IRQ + NAPI + consumer 프로세스를 모두 같은 코어에 고정) 조건으로 측정한다.

---

## 문제

동일 조건 단일코어에서 UDP는 TCP보다 느리다. 하지만 그 원인은 통념과 다르다.

| 구성 | goodput | core busy | 바이트당 효율 |
|---|---|---|---|
| Linux 기본값 UDP (208KB rcvbuf) | 8-22 G | 26-55% | — |
| TCP (최적: DIM off, rmem 6MB) | 39.6 G | 100% | 0.396 G/%CPU |
| **UDP 최적 구성** | **47.9 G @0.29% loss** | 98% | **0.489 G/%CPU** |

**UDP RX는 per-byte로 TCP보다 싸다.** 문제는 처리 비용이 아니라
**수신 버퍼 오버런과 그로 인한 상태 붕괴(collapse)** 이고, 이를 제거하면
같은 코어 하나로 TCP보다 **21% 높은 처리량**을 낸다.

최적 구성 = 정적 rcvbuf 1.5 MB + DIM off + app GSO/GRO (+ flood 시에만 shed)

### 확인된 사실 (측정 기반)

1. **드롭은 NIC ring이 아니라 socket buffer에서 발생** — `UdpRcvbufErrors`가 `rx_out_of_buffer`의 15~18배
2. **lock도 syscall도 병목이 아니다** — producer lock을 99.9% 줄여도(patch 0003),
   recvmsg를 100배 줄여도(patch 0004) throughput 변화 없음
3. **bistable**: 같은 offered rate에서 0% loss와 20%+ loss가 갈린다.
   상태는 **flow 시작 첫 1초에 결정**되고 30초간 전이가 일어나지 않는다.
   원인은 **DIM(적응형 인터럽트 모더레이션)** 이며, 끄면 43 Gbps가 3/3 결정적으로 나온다
6. **threaded NAPI는 해법이 아니다**: flood에서 19.2 G로 shed 없는 경우(19.6 G)와 동일.
   문제는 스케줄링 공정성이 아니라 버려질 패킷에 낭비되는 작업량이다
7. **캐시 효과는 TCP에서도 재현된다**: `tcp_rmem` 상한을 6MB에서 512MB로 올리면
   39.3 → 33.8 G (-14%), IPC 0.94 → 0.77. 프로토콜 무관한 일반 현상이다
4. **bad state의 정체는 DRAM-bound**: IPC 1.08→0.64, cache-miss 17.5%→44%,
   LLC-miss 3.1배. 큐에 536MB가 적체되어 copyout 시점에 데이터가 캐시에서 밀려남
5. **GRO는 무죄**: 두 상태에서 recvmsg 반환 크기 분포가 동일 (32-64KB super-skb)

---

## 수정 사항

| patch | 내용 | 결과 |
|---|---|---|
| `0006-udp-rcvbuf-autotune` | occupancy(`rmem > rcvbuf/2`) 기반 `sk_rcvbuf` 동적 확장 | 기본값 208KB에서 **수동 512MB 튜닝과 동일 성능**. plain 6.0→22 G (3.7배). 실사용 메모리는 1/100 |
| `0007-udp-early-drop` | socket layer에서 overflow 시 whole-skb 선폐기 | **효과 없음 (negative result)** — 그 지점은 이미 skb build/GRO/스택 비용을 지불한 뒤라 너무 늦다 |
| `0008-udp-rx-shed-driver` | overflow 시 RX 큐에 shed window를 걸고 **mlx5 CQE 레벨**(skb 생성 전)에서 폐기 | flood 시 goodput **9.5→16.7 G (+76%)**, `%soft` 52→27, consumer `%sys` 34→58 |

세 기능 모두 sysctl 런타임 토글이라 재부팅 없이 A/B 가능:
`net.ipv4.udp_rmem_autotune`, `udp_rmem_autotune_max`, `udp_early_drop`, `udp_rx_shed`

### 설계 원칙

> **UDP 수신 버퍼의 상한은 "메모리"가 아니라 "캐시" 기준으로 정해야 한다.**

버퍼 크기는 비단조(non-monotonic) 최적점을 가진다. 너무 작으면 GSO 버스트를 흡수하지 못하고,
너무 크면 적체가 LLC를 넘겨 copyout이 DRAM-bound가 된다.

정적 버퍼 크기 스윕 (진짜 단일코어, 2회 평균, L3 = 36 MiB):

| 정적 버퍼 | b=35G | b=40G | flood 82G | flood busy |
|---|---|---|---|---|
| 208 KB (리눅스 기본값) | 8.4 G | 12.8 G | 7.3 G | 34% |
| 512 KB | 23.8 G | 23.6 G | 15.6 G | 55% |
| 1 MB | 34.0 G | 37.1 G | 25.4 G | 80% |
| **1.5 MB** | 34.2 G | **38.8 G** | **32.3 G** | **99%** |
| 3 MB | 34.4 G | 37.5 G | 26.9 G | 100% |
| 8 MB | 34.6 G | 33.9 G | 21.8 G | 100% |

최적점은 **1.5 MB = L3의 1/24**. 기본값 대비 4.4배, 512 MB 대비 2배다.
양쪽 실패 원인이 다르다는 점이 중요하다.

- **너무 작으면**(208 KB~512 KB) core busy가 26~55%에 그친다. CPU가 남는데도 받지 못한다 —
  GSO 버스트를 흡수하지 못해 shed가 과도하게 발동한다.
- **너무 크면**(3 MB 이상) core busy는 100%인데 goodput이 떨어진다. 적체가 LLC를 넘겨
  copyout이 DRAM-bound가 되는 순손실이다.
- **1.5 MB만 busy 99%** 로 낭비 없이 포화한다. b=40G에서 38.8 G로 TCP(36.5 G)를 넘는다.

---

## 저장소 구성

```
patches/   커널 및 iperf3 패치 (0001-0008)
           iperf3 패치는 receiver/sender 빌드가 다르므로 주의 (ENVIRONMENT.md)
scripts/   실험 자동화 스크립트 (baseline, A/B, sweep, perf/bpftrace probe)
tools/     벤치마크 도구 (udp_blast, udp_sink, af_xdp_sink)
results/   측정 결과 요약 (raw 로그는 제외, summary와 CSV만)
docs/      분석 노트, 설계 문서, 실험 환경 문서
```

주요 문서:
- [`docs/ENVIRONMENT.md`](docs/ENVIRONMENT.md) — 하드웨어·커널 변종·**단일코어 측정 방법론**(필독)
- [`docs/udp_recv_optimization_design.md`](docs/udp_recv_optimization_design.md) — 비용 분해와 Tier별 최적화 설계
- [`docs/260917_DailyNote.md`](docs/260917_DailyNote.md) — baseline 확정부터 shed 구현까지의 전체 실험 기록

## 재현

```bash
# 1. 환경 검증 후 baseline (docs/ENVIRONMENT.md의 방법론 필수)
./scripts/baseline_confirm_1c.sh vanilla30s 3

# 2. autotune A/B (stock / 수동 512MB / autotune)
./scripts/ab_autotune_1c.sh 2

# 3. driver-level shed A/B
./scripts/ab_shed_1c.sh 2

# 4. collapse curve (논문 Figure)
./scripts/sweep_collapse_curve.sh 2

# 5. 버퍼 크기 최적점 정밀 스윕
./scripts/sweep_static_rcvbuf.sh 2 15
```

스크립트는 control node(WSL2)에서 실행하며 sslab3/sslab4에 SSH로 명령을 보낸다.

## 상태

- [x] baseline 확정 (vanilla, 진짜 단일코어, 30s×3)
- [x] 비용 분해 (perf, bpftrace)
- [x] rcvbuf autotune 구현·검증
- [x] driver-level RX shed 구현·검증
- [x] bistability 원인 규명 (캐시 지역성)
- [x] 버퍼 최적점 정밀 확정 (1.5 MB)
- [ ] autotune 기본 cap을 32 MB에서 1.5 MB로 수정
- [ ] shed 히스테리시스 / startup guard (상태 진입 제어)
- [ ] transparent GRO (app opt-in 없이 GRO 이득 제공)
