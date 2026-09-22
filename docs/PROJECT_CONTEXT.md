# 프로젝트: 단일코어 UDP 수신 경로 분석 + 커널 수정 (네트워크시스템설계 텀프로젝트)

## Control node
- 당신은 **Windows WSL2 (Ubuntu)** 에서 실행 중. 양쪽 실험 서버에 SSH로 접근.
- **Receiver (server): `ssh sslab4 "<cmd>"`**
- **Sender (client):   `ssh sslab3 "<cmd>"`**
- 양쪽 NOPASSWD sudo: perf, bpftrace, ethtool, sysctl, tcpdump, nstat, ip, tee

## 환경
- OS: **Ubuntu 20.04.6 LTS** (gcc 9.4.0, binutils 2.34, pahole 1.21, make 4.2.1)
  - 이 툴체인으로 6.18.53 빌드 요건 충족 (min gcc 8.1 / binutils 2.30 / pahole 1.16)
- 커널:
  - 구 baseline: 6.6.9 계열 (sslab4에 `-vanilla/-autotune/-udprx1/2/3` 변종 존재)
  - **현행 타깃: sslab3 = `6.18.53-vanilla618`(순정), sslab4 = `6.18.53-udpopt618`(패치 0009)**
- 양쪽 IPMI(`/dev/ipmi0`) 있음 → 커널 부팅 실패 시 전원 복구 가능.
  새 커널은 항상 `grub-reboot` one-shot 으로 먼저 띄운다 (실패 시 다음 부팅에 자동 복귀).
- NICs:
  - **`ens81f0np0` = NVIDIA ConnectX-5 (mlx5_core, 100Gbps) ← 메인 실험 NIC**
  - `ens102f0np0` = Intel E810 (ice driver, 100Gbps) — 별도 비교용
  - `ens102f1np1` = SoftRoCE 용 (현재 DOWN)
- 실험 IP (ens81f0np0, CX5):
  - **sslab4 (receiver): 192.168.11.238**
  - **sslab3 (sender):   192.168.11.120**
- iperf3 server는 sslab4에서 `-B 192.168.11.238`, client는 sslab3에서 `-c 192.168.11.238`
- MTU 9000 (jumbo, 양쪽 ens81f0np0)
- iperf3 binary: `~/iperf3-source/src/iperf3` (양쪽, UDP GSO/GRO 지원 수정판)
  - **두 호스트의 소스가 다르다** (receiver 쪽에만 drain loop 추가). 패치는
    `patches/0005-...-receiver.patch` / `0005b-...-sender.patch` 로 분리 보관.
  - GSO 는 env 가 아니라 `blksize > gso_size(=MTU-28)` 조건으로 켜진다.
  - `IPERF3_UDP_GRO` 는 **receiver(sslab4)** 에 걸어야 한다. sender 에 걸면 아무 효과 없음.

## 단일코어(true single core) 방법론  ← 모든 실험의 전제
aRFS 는 **쓰지 않는다.** 큐를 하나로 줄이고 IRQ 를 직접 못박는다.
```
ethtool -L ens81f0np0 combined 1          # RX 큐 rx-0 하나만
전 msi_irq smp_affinity = 0x2             # cpu1 고정
systemctl mask irqbalance                 # 재배치 방지
cpufreq governor = performance            # 양쪽
taskset -c 1 <consumer>                   # 소비자도 같은 코어
ethtool -C ens81f0np0 adaptive-rx off     # DIM 제거 (비교 arm 아닐 때)
```
- aRFS(`ntuple`)는 **여러 큐 사이** 스티어링이라 큐가 1개면 무의미하고, 동적 재프로그래밍이
  비결정성을 도입하므로 오히려 해롭다. `ntuple-filters off`, `rps_sock_flow_entries 0` 확인.
- **RPS 도 반드시 off** (`rx-0/rps_cpus=000000`). 켜져 있으면 softirq 가 다른 코어로
  퍼져 "1코어" 주장 자체가 거짓이 된다.
- 검증: `/proc/interrupts` 에서 `mlx5_comp1` 이 cpu1 에 99.99%+ 집중되는지 확인.
- 2코어 분리(`l2split`/`l3split`)는 **진단용 대조군**일 때만 허용. 성능 주장 금지.

## 헬퍼 스크립트 (`~/lab/scripts/`)
- `run_experiment.sh` / `run_with_monitoring.sh` / `bpf_remote.sh` — 구 범용 러너
- `probe_l2_hypothesis.sh` — 캐시 공유 레벨 × 버퍼 스윕 (핵심 실험)
- `probe_mtu1500.sh` / `sweep_mtu1500_tuning.sh` / `ab_gro_mtu1500.sh` — MTU 1500 적용범위
- `sweep_expected_goodput.sh` / `sweep_static_rcvbuf.sh` / `ab_shed_1c.sh` 등
- `remote_build_618.sh` (호스트에서 실행) / `deploy_618.sh` (control node)
- 결과: `~/lab/logs/<name>_<timestamp>/`
- 기록: `~/lab/260917_DailyNote.md`, repo `~/UDP-Optimization` (GitHub: Neoul03/UDP-Optimization)

## 커널 소스 (코드 인용은 파일:라인 형식)
- `~/lab/kernel/linux-6.6.9/`   — 구 baseline
- `~/lab/kernel/linux-6.18.53/` — **포팅 타깃 (최신 LTS)**
- `~/lab/kernel/linux-7.2.7/`   — 감사용 (최신 stable). 7.x 계열엔 아직 LTS 없음.
- `~/lab/kernel/port618/{orig,work}/` — 0009 패치 생성용 작업본

## 작업 규칙
1. 명령마다 어느 호스트인지 명시. **server=sslab4, client=sslab3.**
2. 실험 후 cleanup 확인: `ssh <host> "pgrep -a '[i]perf3' || echo clean"`
   - **`pkill -f 'iperf3 -s'` 는 자기 자신을 죽인다.** 반드시 `'[i]perf3 -s'` 브래킷 표기.
3. bpftrace 는 `timeout` 으로 감싼다.
4. SSH 느려지면: `ssh -O exit sslab3 && ssh -O exit sslab4 && rm -f ~/.ssh/cm-*`
5. **실험 IP(192.168.x.x)로 SSH 금지.** 관리망은 115.145.x.x.
6. 원격 백그라운드는 `setsid nohup ... &` 대신 **로컬에서 ssh 클라이언트를 백그라운드로** 돌린다.
7. perf 는 `/usr/lib/linux-tools/<ver>/perf` 절대경로로 호출.
8. bash `set -u` 에서 `local a="$1" b="$a"` 는 깨진다. `local` 을 줄마다 분리할 것.

### ★ 측정 원칙 (같은 실수를 여섯 번 했다. 반드시 지킬 것)
1. **N=1 비교 금지.** 이 계의 변동계수는 구간에 따라 0.5~14%다. 단일 시행 차이
   10~20% 는 전부 잡음일 수 있다. **모든 비교는 N>=5, 평균±sd 로만 판단.**
   (실제 사고: "ring 128 에서 +18%, 46.0G 무손실" -> N=10 평균은 41.1, 그냥 뽑기였음)
2. **한 점만 보고 일반화 금지.** 특히 제공률(offered rate) 한 점에서 잰 결론을
   전 구간으로 확장하지 말 것. **레버의 효과는 동작점에 따라 부호까지 바뀐다.**
   (실제 사고: 46G 한 점에서 "ring 은 UDP 에 무효" -> 56G 에서는 +17.4%)
   (실제 사고: 46G 한 점에서 "UDP 가 TCP 에 진다" -> 52G 에서는 UDP 가 +21%)
3. **사다리는 값이 꺾일 때까지 늘릴 것.** 끝점에서 아직 상승 중이면 천장을 못 찾은 것이다.
4. **sender flake 를 반드시 배제.** tx < 0.97*offered 면 그 시행은 버린다.
   (rx 만 보면 sender 문제를 receiver 붕괴로 오독한다)
5. 연속 성공/실패를 결정론으로 읽지 말 것. p=0.56 이면 3연속은 5번에 1번 일어난다.
6. **비교의 한쪽에만 제약을 걸어놓고 잊지 말 것.** 반복해서 당한 유형이다:
   - `adaptive-rx off` — 반증된 DIM 가설의 잔재가 이후 모든 실험의 기본값으로 남았다
   - `tcp_rmem='4096 1M 1M'` — 워킹셋을 맞추려 TCP 의 DRS 를 껐고, 그 상태로 잰
     43.3G 를 TCP 기준선으로 써서 "UDP 가 +31% 빠르다" 고 주장했다.
     기본값(6MB)으로 재면 TCP 는 51.4G, 실제 차이는 +10.5% 였다.
   **"A vs B" 를 주장하려면 양쪽 다 각자의 최선 설정에서 재야 한다.**
   워킹셋을 맞춘 비교는 메커니즘 분석용이지 성능 주장용이 아니다.
7. **측정 도구를 의심 목록에 넣을 것.** `iperf3 -u -b` 의 `clock_nanosleep` 기상 지연이
   버스트 열차를 만들어 천장 아래에서 가짜 손실을 만든다. 여섯 개 가설을 세우고
   전부 기각한 뒤에야 도구를 의심했다. 수신 경로 실험은 `udp_blast`(byte-budget
   pacing) -> `udp_sink` 를 쓴다.

### 함정 (실제로 당한 것들)
- **리부팅하면 MTU 가 1500 으로 리셋된다.** 모든 스크립트가 시작 시 MTU 를 세팅하고
  양쪽에서 assert 할 것. (MTU 1500 으로 baseline 매트릭스 하나를 통째로 날렸다)
- **`mpstat` 의 `%soft` 는 신뢰할 수 없다** — 동일 조건에서 4~94% 로 요동한다.
  NAPI 가 inline 이냐 ksoftirqd 냐에 따라 %soft/%sys 분류가 갈리기 때문.
  **`busy`(=100-idle)만 사용**하고 첫 3-4 샘플은 ramp-up 이므로 버린다.
- **sender flake**: sslab3 가 간헐적으로 offered 보다 낮게 (전형적으로 ~29.4G) 송신한다.
  `tx < 0.97 × offered` 면 자동 재시도할 것. 원인 미규명.
- permission classifier 가 막는 패턴: cpufreq governor 를 glob 루프로 쓰는 것
  (`for g in /sys/.../scaling_governor; do echo performance | sudo tee $g`).
  governor 는 이미 performance 이므로 스크립트에서 빼고 assert 만 한다.
- `-b 0` (blast) 는 livelock 을 유발한다. soft 99%, consumer 기아, rx 집계 실패.

## 출력 형식
- **모든 분석/보고는 한국어.** 코드/명령/함수명/파일경로는 영어 그대로.
- evidence class 필수: (a) 코드/로그에서 직접 확인 / (b) 강한 추론 / (c) 검증 필요한 가설
- 구조: Observation → Interpretation → Limitation → Next validation step
- 사족 없이 lab note 밀도.

## 이미 확인된 사실 (재유도 금지)
### 코드 구조
- TCP 는 lock_sock 1회로 다수 skb 배치 소비, UDP 는 datagram 당 spinlock (6.6.9 기준).
- UDP 는 sk_backlog 미사용 (lock_sock 자체를 안 잡는 architectural choice).
- **6.18.53/7.2.7 에서 `busylock` 제거되고 per-NUMA `udp_prod_queue` llist 도입**
  (`net/ipv4/udp.c:1699~`). 우리 패치 0003 은 upstream 이 더 낫게 구현 → 폐기.
- **rcvbuf autotuning 은 7.2.7 에도 없다** — `rcvbuf = READ_ONCE(sk->sk_rcvbuf)` 뿐.
- **수신 경로에 캐시 인지형 버퍼 사이징이 전무**. `udp_mem` 은 RAM 기반
  (`limit = nr_free_buffer_pages()/8`). `cache_size|llc_size|l3_size` grep 0건.
- GRO 한계 상수 7.2.7 까지 불변: `MAX_GRO_SKBS 8`, `GRO_HASH_BUCKETS 8`,
  `UDP_GRO_CNT_MAX 64`. → 동시 flow M 개면 merge depth ≈ 64/M 로 붕괴.

### 하드웨어 (sslab4, Xeon Silver 4310 Ice Lake-SP, 2소켓×12코어)
- core1 기준: L1d 48K / **L2 1280K(코어 전용)** / L3 18432K(cpu0-11 공유)
- `lscpu` 의 "L3 36 MiB" 는 2소켓 합이다. 혼동 금지.
- Intel RDT/CAT 지원 (`cat_l3 mba rdt_a cqm_occup_llc`). resctrl 은 마운트 필요.
- perf 심볼 L2 이벤트 없음(vendor JSON 미설치). ICX raw: L2_RQSTS.MISS=r3f24,
  REFERENCES=rff24, MEM_LOAD_RETIRED.L2_HIT=r02d1, .L2_MISS=r10d1, .L3_MISS=r20d1

### ★ 핵심 메커니즘 (확정)
**수신 버퍼 크기 효과 = producer→consumer 캐시 핸드오프 효과.**
producer(NAPI)/consumer(recvmsg) 를 분리해 공유 캐시 레벨만 바꾼 실험 (blast, shed off):

| 공유 캐시 | 512K→18M 처리량 비 |
|---|---|
| L2+L3 (같은 코어) | **0.40** |
| L3 만 (같은 소켓) | **0.61** |
| 없음 (다른 소켓) | **0.94** ← 사실상 무효 |

잃을 공유 캐시가 없으면 버퍼 크기는 무의미하다. 이 하나로 MTU 1500 평탄 곡선,
2코어 분리 시 붕괴 완화, bad state 의 cache-miss 44%/IPC 0.64 가 전부 설명된다.

### ★ 철회된 주장 (다시 쓰지 말 것)
- ~~"DIM 이 UDP 폭락/bistable 붕괴의 원인"~~ → **반증**. 46G 고정 N=10 에서 on 4/10,
  off 4/10. 구 수치(MTU 8192, UDP DIM on 4.8 / off 19.4)는 `-l 9000` IP fragmentation
  artifact 였다. **`-l` 은 8972 를 쓸 것.**
- ~~"캐시 기반 역U자 최적점 1.5MB"~~ → **confound**. 그 스윕은 `udp_rx_shed=1` 로 돌았고,
  버퍼가 작으면 shed 윈도가 상시 활성이라 왼쪽 절벽을 shed 가 만들었다. shed off 로
  재측정하면 512K~18M 단조 감소, 봉우리 없음.
- ~~"rate resonance(특정 속도에서 나쁨)"~~ → 0.5G 스윕으로 반증, 전 구간 동전던지기.
- ~~"consumer 스케줄링 우선순위 / 서버 프로세스 메모리 레이아웃 / sender 버스트 구조"~~
  → 전부 bistable 진입 원인 아님으로 반증.

### ★ 성능 기준점 (6.18.53, 1코어, MTU 9000, ring 128)  ← 현행
| | 값 | 조건 |
|---|---|---|
| **TCP 최고** | **51.4 G** (cv 1.4%, busy 98%) | 기본 `tcp_rmem` (max 6MB), N=10 |
| TCP (rmem 1M 제약) | 42.9 G | **성능 주장에 쓰지 말 것** — DRS 를 끈 값 |
| **UDP 최고** | **56.8 G** @ 58G 제공 | ring 128, buf 1M, N=15 |
| **UDP/TCP** | **+10.5%** | 양쪽 다 CPU 포화, 각자 최선 설정 |
| UDP ring 1024 | 48.1 G @ 52G | ring 만 바꾼 비교 -> ring 효과 +18% |

과거 기준점 (6.6.9-udprx3, 참고용. 커널 config 가 달라 직접 비교 금지):
TCP 39.6G / UDP 기댓값 48.5G @52G.
MTU 1500: Linux 기본(rmem 208K) 21-22G → 튜닝 32G, TCP 33.1G.
app GRO 레버: MTU 9000 에서 85%→65% busy, MTU 1500 에서 100%→65%.

### shed 효과 (6.18.53-udpopt2, N=10, udp_blast→udp_sink)
| offered | shed off | shed on |
|---|---|---|
| 48G | 47.8 (busy 93%) | 47.9 (93%) |
| 52G | 45.15 | **51.82** (무손실급 99.65%) |
| 60G | 41.78 | **48.75** |

천장 아래 무해, 천장 너머 +15~17%, 무손실 천장 48→52G.
**protocol-aware 검증 완료** (단일 큐 공유 최악 조건, TCP+UDP60G 동시):
TCP 13.8 → **22.1 (+60%)**, UDP 23.2 → 25.3. 둘 다 개선.

## 패치 현황
| 패치 | 상태 |
|---|---|
| 0001/0002 net_dim | 폐기 (DIM 반증) |
| 0003 batch enqueue | 폐기 (upstream `udp_prod_queue` 가 대체) |
| 0004 UDP_RECV_BATCH | 폐기 (GRO 켜면 무의미) |
| 0005/0005b iperf3 | 유지 (측정 도구) |
| 0006 rcvbuf autotune | → 0009 로 통합, **default off** |
| 0007 early drop | 폐기 (음성 결과) |
| 0008 driver shed | → 0009 로 통합, **default off**. 작은 버퍼에 지배당하는지 확인 필요 |
| **0009 (6.18.53)** | `udp_rmem_autotune` / `udp_rmem_autotune_max` / `udp_rx_shed`, 전부 default 0 |

0009 는 두 기능 모두 default-off 라 knob 을 끄면 **동작상 upstream 과 동일**하다.
따라서 receiver 에 vanilla 를 따로 빌드할 필요 없이 같은 부팅에서 baseline/실험군 A/B 가능.

## 범위 결정 (사용자 지시, 2026-09-22)
- **실제 프로토콜 벤치마크(QUIC/HTTP3, SRT/RIST, WebRTC, DNS 등)는 당분간 하지 않는다.**
  어떤 프로토콜이 우리 path 를 타는지 판단만 해뒀고, 실행 큐에서 제외.
  (참고: QUIC 은 평범한 UDP 소켓이라 우리 path 를 100% 탄다.
   VXLAN/GTP/L2TP/WireGuard/ESP-in-UDP/SoftRoCE 는 `encap_rcv` 훅에서 빠져
   `sk_rcvbuf` 를 안 쓴다. HW RoCEv2 는 커널에 들어오지도 않는다.)
- 커널 UDP 수신 path 자체에 집중한다.

## 현재 과제
1:1 static 에서 메커니즘을 확정한 뒤 multi-flow 로 확장한다.
- **Phase 1 (진행 중)**: 캐시 핸드오프 메커니즘 정량화.
  체류시간 가설(버퍼↑ → 소비 전 축출 → copyout 이 DRAM 히트)을 L2/L3 miss raw counter 로 확인.
  shed 가 "작은 버퍼"에 지배당하는지 직접 비교 (shed off+512K=37.8 vs shed on 최고 33.2).
  46G bistable 구간은 버퍼별 N≥5 필요.
- **Phase 2**: 6.18.53 배포 후 baseline 재측정. upstream `udp_prod_queue` 가 6.6.9 대비
  얼마나 올려주는지 정량화.
- **Phase 3**: multi-flow. many→one(소켓 1개, GRO merge depth 붕괴) 와
  many→many(소켓 N개, 전역 캐시 예산 분배) 를 분리해서 볼 것.
  여기서 비로소 autotune 과 dynamic balancing 이 존재 이유를 얻는다.

논문 프레이밍: "rmem 을 N MB 로 맞춰라"(약함)가 아니라
**"수신 버퍼 상한은 메모리가 아니라 producer/consumer 가 공유하는 캐시에서 유도되어야 한다"**(강함).
