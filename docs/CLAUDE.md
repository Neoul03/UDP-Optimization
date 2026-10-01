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
- **`/dev/ipmi0` 은 in-band 라 부팅 실패 복구에 쓸 수 없다.** 호스트가 죽으면
  그 장치도 같이 죽는다. 복구에 필요한 건 **out-of-band BMC 주소 + 자격증명**이고,
  그건 어디에도 기록돼 있지 않다 (2026-09-25 에 sslab4 를 못 살려 사용자에게
  요청해야 했다). BMC 는 호스트 IP 와 인접하지 않는다 — sslab3 호스트 `.120`,
  BMC `115.145.211.58`. **sslab4 BMC 주소를 알게 되면 여기 적을 것:** `TODO`
  ```
  ssh sslab3 "sudo ipmitool -I lanplus -H <BMC> -U <u> -P <p> chassis power cycle"
  ```
- 새 커널은 항상 `grub-reboot` one-shot 으로 띄운다. **단 그건 패닉/자동 재부팅
  에서만 복귀시켜준다** — hang 하면 아무 일도 안 일어나고 전원 사이클이 필요하다.
- **★ 빌드 완료 감지를 `vmlinuz` 로 하지 말 것. `initrd` 로 해야 한다.**
  `make install` 은 `INSTALL /boot` 에서 vmlinuz 를 먼저 놓고, 그 **뒤에**
  `update-initramfs` 가 수 분간 돈다. vmlinuz 존재를 완료 신호로 쓰면 initrd 생성
  중에 재부팅을 걸어 SIGTERM 으로 죽이게 되고, initrd 없는 커널은 루트를 마운트
  못 해 **부팅 즉시 패닉**한다. (2026-09-25, v17. 로그에
  `make[1]: *** [arch/x86/Makefile:321: install] Terminated` 가 증거.
  IPMI 자격증명이 없어 사용자에게 전원 사이클을 요청해야 했다.)
  올바른 대기 조건:
  ```
  until ssh sslab4 "test -s /boot/initrd.img-<ver>"; do sleep 60; done
  ```
  `remote_build_618.sh` 가 마지막에 네 가지를 assert 하고 `READY` 를 찍는다.
  **`READY` 가 없으면 부팅하지 말 것.** 단 이 스크립트는 **호스트에 있는 사본이
  실행된다** — 로컬(`~/lab/scripts/`)만 고치고 `scp` 를 잊으면 방지 장치가 없는
  구 버전이 돈다 (v18 에서 실제로 그랬다). 고칠 때마다 같이 보낼 것.
- **재부팅 전에 네 가지를 모두 assert 할 것:**
  `/boot/vmlinuz-<ver>` / `/boot/initrd.img-<ver>`(**150MB 내외**) /
  `/lib/modules/<ver>/` 에 .ko 수천 개 / `grep -c <ver> /boot/grub/grub.cfg` > 0.
  **`update-grub` 이 자동으로 안 돌았으면 그 자체가 install 중단 신호다.**
  grub 만 수동으로 고치고 띄우지 말 것 — 그러다 부팅 불가가 됐다.
  복구는 `sudo update-initramfs -c -k <ver>` 후 `update-grub`.
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
- **측정 전에 서버가 유휴인지 확인할 것.** 커널 빌드를 백그라운드로 띄워두고
  같은 서버에서 측정해 47.9G 를 26.4G 로 쟀다. `ps -eo pcpu,comm --sort=-pcpu | head -3`
  으로 확인하고, 빌드 직후라면 initrd 생성(`lz4`/`cpio`)까지 끝나길 기다릴 것.
- **`udp_sink` 는 `SO_RCVBUF` 로 64MB 를 요청한다** (`tools/udp_sink.c`).
  커널이 2배로 128MB 를 준다. 따라서 `rmem_default` 를 아무리 바꿔도
  **`rmem_max` 가 크면 전부 128MB 가 된다.** 버퍼 스윕이 통째로 무의미해진다.
  → 버퍼를 스윕하려면 **`UDP_SINK_NO_RCVBUF=1`** 을 쓰거나
     `rmem_max = rmem_default` 로 같이 묶을 것. (세 번 당했다)
- **`CONFIG_MAX_SKB_FRAGS` 를 올리면 mlx5 NIC 이 안 올라온다.** 45 로 빌드하면
  `MLX5E: Max SQ WQEBBs firmware capability: 16, needed 23` 으로 probe 실패하고
  ens81f0np0 이 사라진다. `MAX_SKB_FRAGS` 가 TX WQE 크기 계산에 직접 들어가고
  (`en/txrx.h:30`), 기본값 17 이 이미 펌웨어 한계 16 WQEBB 와 정확히 같다.
  → **이 NIC 에서 올릴 수 없는 값이다. 재시도 금지.**
- **리부팅하면 MTU 가 1500 으로 리셋된다.** 모든 스크립트가 시작 시 MTU 를 세팅하고
  양쪽에서 assert 할 것. (MTU 1500 으로 baseline 매트릭스 하나를 통째로 날렸다)
- **리부팅하면 cpufreq governor 가 `ondemand` 로 리셋된다** (2026-10-01, v21 부팅 후
  사다리가 `FATAL governor=ondemand` 로 거부됐다). ondemand 로 재면 주파수가 부하
  따라 흔들려 모든 기준선과 비교가 안 된다. **부팅 직후 `scripts/set_governor.sh` 를
  돌릴 것.** 측정 스크립트는 governor 를 세팅하지 말고 **assert 만** 한다 (글롭으로
  `sudo tee` 하는 형태가 permission classifier 에 걸린다).
- **리부팅하면 `adaptive-rx` 도 on 으로 리셋된다.** 그리고 이건 무해하지 않다 —
  48G/rmem 1M/shed off 에서 on 은 cv 20% 의 bistable, off 는 cv 0.005% 로 47.92 고정.
  과거 기준선은 전부 off 에서 잰 값이므로 **on 상태로 재면 기준선과 비교가 안 된다.**
  스크립트마다 명시적으로 세팅하고 어느 쪽인지 로그에 남길 것.
- **`mpstat` 의 `%soft` 는 신뢰할 수 없다** — 동일 조건에서 4~94% 로 요동한다.
  NAPI 가 inline 이냐 ksoftirqd 냐에 따라 %soft/%sys 분류가 갈리기 때문.
  **`busy`(=100-idle)만 사용**하고 첫 3-4 샘플은 ramp-up 이므로 버린다.
- **sender flake**: sslab3 가 간헐적으로 offered 보다 낮게 (전형적으로 ~29.4G) 송신한다.
  `tx < 0.97 × offered` 면 자동 재시도할 것. 원인 미규명.
- permission classifier 가 막는 패턴: cpufreq governor 를 glob 루프로 쓰는 것
  (`for g in /sys/.../scaling_governor; do echo performance | sudo tee $g`).
  governor 는 이미 performance 이므로 스크립트에서 빼고 assert 만 한다.
- `-b 0` (blast) 는 livelock 을 유발한다. soft 99%, consumer 기아, rx 집계 실패.
- **goodput 을 커널 카운터로 재지 말 것.** 둘 다 틀린 값을 준다:
  - `/sys/class/net/*/statistics/rx_bytes` 는 **선 위의 바이트**라 drop 된 것까지 센다.
    offered 를 재는 것이지 goodput 이 아니다.
  - `/proc/net/snmp` 의 `Udp: InDatagrams` 는 **GRO super-skb 단위**다. datagram 수가
    아니므로 8972 를 곱하면 GRO merge factor(실측 ~6.3)만큼 과소 계상된다.
  - 같은 줄에서 `$5` 는 `RcvbufErrors` 가 아니라 `OutDatagrams` 다 (`$6` 이 맞다).
  → 구간별 처리량이 필요하면 **`UDP_SINK_INTERVAL=<초>`** 로 sink 가 stderr 에 찍는
     누적 바이트(`[iv] t=.. bytes=..`)를 diff 할 것. 배달된 바이트는 앱만 안다.
- **WSL 에서 `git push` 가 HTTP 408 로 실패한다.** `RPC failed; HTTP 408` +
  `send-pack: unexpected disconnect` + (오해를 부르는) `Everything up-to-date`.
  **크기 문제가 아니다** — blob 0.0MB / 4,259 줄에서도 났다. HTTP/2 multiplexing
  이슈이고 repo 설정 한 줄로 고쳐진다:
  ```
  git config http.version HTTP/1.1
  ```
  (`http.postBuffer` 확대는 무관했다. 실패 후 `git fetch` 로 remote HEAD 를 확인할
   것 — `Everything up-to-date` 만 보고 올라갔다고 판단하면 안 된다.)
- **툴 바이너리를 WSL 에서 빌드해 scp 하지 말 것.** glibc 가 더 최신이라
  `GLIBC_2.38 not found` 로 실행이 안 되고, 기존 정상 바이너리를 덮어써서 날린다.
  → `.c` 를 scp 하고 **서버에서 gcc** 할 것.

## 출력 형식
- **모든 분석/보고는 한국어.** 코드/명령/함수명/파일경로는 영어 그대로.
- evidence class 필수: (a) 코드/로그에서 직접 확인 / (b) 강한 추론 / (c) 검증 필요한 가설
- 구조: Observation → Interpretation → Limitation → Next validation step
- 사족 없이 lab note 밀도.

## 이미 확인된 사실 (재유도 금지)
### 코드 구조
- ~~"UDP 는 datagram 당 spinlock"~~ → **틀린 메모였다. 코드에서 확인(2026-09-29).**
  `__skb_recv_udp()` 는 `reader_queue` 를 먼저 보고, 비었을 때만
  `spin_lock(&sk_queue->lock)` 을 잡아 `skb_queue_splice_tail_init()` 로
  **sk_receive_queue 전체를 한 번에** 옮긴다. 즉 **경쟁하는 락은 배치당 1회**이고
  이후 recvmsg 들은 경쟁 없는 `reader_queue` 락만 잡는다. upstream 이 오래전에
  해결한 것(Abeni 의 reader_queue)이며 우리가 고칠 거리가 아니었다.
- datagram 당 남는 비용은 **recvmsg 시스템콜 / reader_queue dequeue / copyout**
  셋이고 전부 **skb 단위**다. 따라서 skb 하나에 datagram 이 몇 개 들었는지가 전부:
  앱이 `UDP_GRO` 를 켜면 `avg_bytes_per_call` 57,482 (6.4 개), 안 켜면 8,972 (1 개).
  `udp_rcv_segment()` 가 커널이 합친 skb 를 도로 쪼개기 때문이다.
  → **이건 앱이 GRO 를 안 켤 때만 생기는 문제**이고, 패치 0004(UDP_RECV_BATCH)를
     폐기한 이유도 이것이다 (작은 datagram 에서만 21%, 8972B 에선 무의미).
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

### 축소 경로 (v10) 와 유휴 grant
**축소가 복귀 버스트를 해치지 않는다** (56G, N=3). 48G 는 천장 아래라 세 arm 이
전부 47.9 로 구별이 안 되므로 **발산하는 동작점에서 재야 한다**:

| arm | lull 중 버퍼 | 복귀 처리량 |
|---|---|---|
| autotune | **1M 로 반납** | **55.5** |
| static 1M | 1M | 32.0 |
| static 4M | 4M 계속 점유 | 55.4 |

재성장이 충분히 빨라 반납 비용이 관측되지 않는다. 큰 버퍼와 같은 성능을 내면서
유휴 구간엔 예산을 돌려준다.

**단, 축소는 패킷 도착 시에만 평가된다** — sender 가 아예 멈추면 회수 경로가 없고
소켓이 살아 있는 한 grant 를 쥔다. 예산을 고갈시킨 상태에서 신규 소켓이 56G 를
받으면 1M 에 묶여 **33.4 (vs 회수 시 55.5)**. → v11 에 회수 워커 추가.

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

### ★ rx-frames 가 진짜 변수다 (DIM 재조사, 2026-09-24)
**"DIM 은 무관"이라는 철회는 하필 답이 없는 한 점에서 측정됐다.** 사다리로 다시 재면
무릎에서 **부호가 바뀐다** (rmem 1M, ring 128, shed off, N=5):

| offered | DIM off | DIM on | busy off | busy on |
|---|---|---|---|---|
| 32G | 31.99 (cv 0.0%) | 31.99 (cv 0.0%) | 65% | **50%** |
| 40G | 39.98 (cv 0.0%) | 39.98 (cv 0.0%) | 77% | **60%** |
| 44G | 43.98 (cv 0.0%) | **37.57 (cv 8.8%)** | 84% | 61% |
| 48G | 47.93 (cv 0.0%) | **37.60 (cv 19.7%)** | 91% | 68% |
| 52G | 51.78 (cv 0.0%) | **34.91 (cv 6.3%)** | 97% | 66% |
| 56G | 48.92 (cv 0.6%) | **32.99 (cv 2.3%)** | 100% | 63% |

40G 이하에서는 처리량이 같고 DIM 이 CPU 를 15~17%p **절약한다**. 44G 부터 해롭다.
옛 철회는 46G 한 점이었고 거기가 정확히 전이 구간이라 4/10 이 나왔다 — 측정은
정확했고 해석이 과했다. (옛 "on 4.8 / off 19.4" 는 `-l 9000` 단편화 artifact 로
여전히 무효. `-l` 은 8972 를 쓸 것.)

**기전: DIM 은 진동하지 않는다.** 6/6 시행에서 즉시 `rx-usecs=8 / rx-frames=128` 에
정착하고 전환 0 회. `rx-usecs` 를 정적으로 4~256 스윕하면 전 구간 47.98 / sd 0.00 —
**변수는 `rx-frames` 다.** 그 스윕은 frames 를 32 로 고정해 DIM 이 앉는 지점을
한 번도 안 밟았다. frames 스윕(usecs 8 고정, sd≈0.00, 48G):

| rx-frames | rmem 1M | rmem 8M | autotune |
|---|---|---|---|
| 16 / 32 / 64 | 47.98 | 47.97 | 47.98 |
| 96 | **38.04** | 47.98 | 47.98 |
| **128** ← DIM | **28.93** | **47.86** | **47.89** |
| 192 / 256 | 20.0 | 39.6 | 39.6 |

**절벽이 두 개이고 원인이 다르다:**
1. `frames × pktsize > sk_rcvbuf` → 소켓 버퍼 넘침. 버퍼가 무릎을 옮긴다(96→128).
2. `frames > ring` → **NIC descriptor 소진**. ring 128 에서 `rx_out_of_buffer` 증분이
   frames 128 에 14,958 인데 192 에 **1,161,830** (77배). ring 1024 면 전 구간 0.

ring 1024 는 1 번을 없애지만 LLC 를 16MB 먹어 **−11 Gbps** 다
(8M/frames128: ring128 **47.86** vs ring1024 36.86).

→ **세 양을 세 주체가 서로 모른 채 정한다**: ring(관리자) / rx-frames(DIM 런타임) /
sk_rcvbuf(앱). 제약 세 개가 엮여 있어 어느 주체도 혼자 못 맞춘다.
`frames ≤ ring`, `frames × pktsize ≤ sk_rcvbuf`, `ring_bytes + Σ sk_rcvbuf ≤ LLC`.
**"rmem 을 N MB 로 맞춰라"가 원리적으로 불가능하다는 직접 증거.**
최적 조합 ring128 + 8M + frames128 = 47.86 에 **autotune 이 자동으로 도달한다(47.89)**.

### ★ 기본 설정(DIM on)에서의 레버 가치 — 이게 정직한 headline
지금까지 모든 비교가 `adaptive-rx off` 에서 이뤄졌는데 그건 **손으로 튜닝한** 조건이다.
배포 기본값(DIM on, ring 128, MTU 9000, 1코어, N=3):

| | 40G | 48G | 56G |
|---|---|---|---|
| stock (rmem 1M) | 39.98 (59%) | 35.37 (61%) | 35.65 (64%) |
| **+ shed** | 39.99 (60%) | **47.73** (75%) | **55.00** (83%) |
| **+ autotune** | 39.98 (60%) | **47.85** (73%) | **55.04** (86%) |

56G 에서 **+54%**. GRO 를 끄면(앱이 `UDP_GRO` 미설정 → `udp_rcv_segment()` 재분할)
천장이 내려가고 **shed 가 autotune 을 이긴다** (56G: shed 47.94 vs autotune 43.92,
busy 100%). CPU 포화 구간에서는 **일을 줄이는 레버만 통한다.** 둘은 상보적이다.

**주의: 코드에 DIM 을 인지하는 부분은 한 줄도 없다.** 기존 메커니즘이 커버하는 이유는
점유율이 버스트의 *원인*을 묻지 않고 *결과*에만 반응하기 때문이다. 의도한 설계가 아니다.

### ★★★ 최종 판정 (N=10, 2026-09-25): **sizing 은 필요 없다. cap + discard 로 간다.**
| 설정 | W1 (1소켓×56G) | loss | W2 (8소켓×7G) | loss |
|---|---|---|---|---|
| **모더레이션 on (기본값)** | | | | |
| 고정 1M | 35.4 | 36.9% | 55.7 | 0.6% |
| **고정 1M + shed** | **54.2** | 3.1% | **55.8** | 0.3% |
| 고정 8M | 55.6 | 0.8% | 22.9 | 59.1% |
| 고정 8M + shed | 55.5 | 1.0% | **29.5** | 47.3% |
| 적응형 sizing | 55.4 | 1.0% | 55.6 | 0.7% |
| 적응형 + shed | 55.6 | 0.7% | 55.8 | 0.4% |
| **모더레이션 off** | | | | |
| 고정 1M + shed | **52.7** | 5.9% | **52.3** | 6.6% |
| 적응형 + shed | 48.9 | 12.8% | 51.5 | 8.0% |

**"정적 값은 없다"는 주장한 형태로 반증됐다.** 고정 1M + shed 가 두 워크로드를 다
잡는다. 적응형은 모더레이션 on 에서 2.6% 앞서고, **off 에서 7% 뒤지고, 천장 너머에서
4~6% 뒤진다**(과부하 사다리: 64/72/80G 에서 1M+shed 62.7/61.4/60.9 vs 적응형+shed
58.8/58.1/58.6). 어느 쪽도 지배하지 않으며, **고정 1M+shed 가 어디서도 최선에서 멀지
않은 유일한 설정**이고 소켓별 상태 기계가 필요 없다.

**그런데 shed 는 큰 버퍼를 구제하지 못한다**: 8M×8 은 22.9 → 29.5 에서 멈춘다
(1M+shed 의 55.8 대비 절반, 여전히 47% 손실). **일을 줄이는 것과 용량을 줄이는 것은
다르고, 캐시를 밀어내는 건 용량이다.** → cap 은 여전히 필요하다.

**주의: 현재 cap 은 성장만 거절하고 초기 할당은 계상만 한다.** `rmem_default=8M` ×
8소켓은 64MB 를 그냥 가진다. 위 8M 행은 **cap 이 필요하다는 증거이지 우리 cap 이
그걸 강제한다는 증거가 아니다.** 초기 버퍼 clamp 는 미구현.

**멀티코어는 이 하드웨어에서 측정 불가**: 1코어가 55G 이므로 2코어면 100G 링크가
먼저 포화한다. 4큐 실험은 전 arm 48.00 / busy 25% 로 아무것도 구별 못 했다.

### 구 헤드라인: v15, autotune 단독으로 두 워크로드 (N=5, DIM on)
| 정책 | W1 (1소켓×56G, 버스트) | W2 (8소켓×7G, 워킹셋) | 최악 |
|---|---|---|---|
| 정적 1M | 32.14 | 55.66 | 32.14 |
| 정적 8M | 55.41 | 23.17 | 23.17 |
| **autotune 단독** | **55.32** | **55.58** | **55.32** |
| autotune + shed | 55.54 | 55.80 | 55.54 |

같은 커널·같은 설정에서 버퍼가 **W1 = 4.4M 하나 / W2 = 1.1M 여덟 개**로 갈린다.
어떤 정적 값도 두 열을 다 이기지 못하고 autotune 은 이긴다. 이게 논문의 핵심 표다.

**단, DIM off 에서는 정적 1M 이 근소하게 낫다** (W1 48.09 vs auto 45.65,
W2 49.05 vs 45.02). 버스트가 없으면 조절할 게 없고 조절 비용만 남는다.
auto+shed 면 48.89/51.21 로 뒤집히지만 auto 단독으로는 못 넘는다. 숨기지 말 것.

### ★ v12~v15 에서 찾은 버그 세 개 (전부 "측정 없이 고치다" 유형)
| ver | 증상 | 원인 |
|---|---|---|
| v12 | W1 55.45 → **36.70** | 목표 갱신이 **level-triggered**. 드레인 분기는 `rmem < rcvbuf>>3` 인 **모든 도착**마다 돈다. 맞게 잡힌 목표가 마이크로초 뒤 "패킷 한 개"짜리로 덮어써짐 |
| v13 | 개선 없음 (38.34) | 축소를 고쳤는데 축소가 원인이 아니었다. **진단 없이 그럴듯한 곳을 고친 것** |
| v14 | W1 복구(54.96), W2 **37.63** | 예산이 **autotune 이 더한 증분만** 계상. 8소켓 × 기본 1M = 8MB 가 안 보여 합이 17.8MB (예산 9MB) |
| v15 | 둘 다 해결 | edge-trigger(찼다가 비어야 주기 완성) + `cmpxchg` 로 **버퍼 전체 1회 계상** + 축소 바닥 `max(target, rmem_default)` |

**교훈: 버퍼 값을 직접 찍기 전까지 "안 자란다"를 몰랐다.** 처리량만 보면
"조금 나쁘다"로 보이지만 `ss -uam` 의 `rb` 를 보면 1M 고정이 바로 보인다.
autotune 실험은 **항상 소켓별 rcvbuf 를 같이 기록할 것.**

### ★ 공정성은 이 하드웨어에서 실증 불가 (정직하게 남길 것)
처리량 Jain 은 전 구간 ≥0.999. 예산을 1.1MB(pct 6)까지 조여도 버퍼 Jain 이
0.89 까지만 벌어진다. 한 코어를 나누는 소켓들은 **어느 하나가 폭주할 만큼의
속도를 못 받는다.** 우리가 본 MIMD 불공정(8M vs 2M)은 **동시 경쟁이 아니라
시간적 래칫**이었고, 그건 v10 축소 + v11 회수가 직접 고친다.
→ AIMD 의 원리적 근거(Chiu & Jain)는 쓰되 **측정으로 뒷받침한다고 주장하지 말 것.**

### ★ autotune 의 성장 정지 결함 (v11 에서 수정)
**autotune 이 정적 1M 보다 나쁜 구간이 있다.** DIM off / 1소켓 / 56G:
정적 1M **48.89** > 정적 8M 40.57 > autotune **38.80**.

원인: 점유율 > 1/2 이면 무조건 두 배로 키우는데, 과부하에서는 큐가 항상 차 있으므로
max 나 예산에 닿을 때까지 계속 큰다. **멈출 이유를 모른다.** 워킹셋은 8M+ring 2M =
10MB 로 LLC 안이라 예산은 통과하지만, 확립된 캐시 핸드오프 곡선(512K→18M 단조 감소)
때문에 큰 버퍼 자체가 손해다.

수정(v11): **큐가 비운 적이 있는가**를 성장 조건에 추가. 비움 1회당 두 배 1회
(`atomic_xchg(&up->rcvbuf_drained, 0)`). 버스트형은 버스트 사이에 비우므로 자라고,
소비자가 못 따라가는 소켓은 한 번도 안 비우므로 그 자리에 멈춘다.

### ★ 제어 법칙의 계보 (논문 프레이밍)
TCP congestion control 유추는 **명시적으로 배제**한다 — sender 피드백 루프가 없고
만들 수도 없다(UDP). 리뷰어의 첫 질문이 될 것이므로 우리가 먼저 말한다.
진짜 선례는 따로 있다:

| 우리 것 | 선례 |
|---|---|
| rcvbuf autotune | **TCP DRS** (`tcp_rcv_space_adjust`) — 같은 문제, 신호만 다름(RTT vs 점유율) |
| 전역 예산 + sweep | **shrinker / memcg** — 하드 용량 제약 + 압력 시 회수 |
| shed | **CoDel 계열 AQM** — 단, **드라이버에 배치**해 버린 패킷이 CPU 를 안 쓴다 |
| drained 게이트 | delay-based CC 의 병목 추론 (Vegas/BBR) |

**현재 성장은 MIMD 다 (두 배/절반).** Chiu & Jain(1989): binary feedback 하에서
AIMD 만 공정성까지 수렴하고 MIMD 는 효율로만 수렴한다. 실제로 "먼저 온 소켓이 4M,
나중 소켓이 1M" 을 관측했고 이건 MIMD 의 알려진 결함이다. → v12 에서 AI 로 전환,
8소켓 Jain index 로 검증.

**v12 설계(예정): 목표값을 탐색이 아니라 유도로.** DRS 는 `rcvbuf = 2 × (1 RTT 수신
바이트)` 다. RTT 의 역할은 "소비자가 한 바퀴 도는 시간"이고, 우리 쪽 그 주기는
**비움에서 비움까지**다. 그 구간의 **최대 점유율**이 곧 `rx-frames × pktsize` 이므로:
`target = 2 × peak_rmem(비움 주기)`. 큐가 한 번도 안 비우면 주기가 완성되지 않아
목표 갱신도 성장도 없다 — drained 게이트가 자연히 포함된다.
이러면 "왜 1/2 인가"라는 질문 자체가 사라진다.

### ★ 철회된 주장 (다시 쓰지 말 것)
- ~~"캐시 기반 역U자 최적점 1.5MB"~~ → **confound**. 그 스윕은 `udp_rx_shed=1` 로 돌았고,
  버퍼가 작으면 shed 윈도가 상시 활성이라 왼쪽 절벽을 shed 가 만들었다. shed off 로
  재측정하면 512K~18M 단조 감소, 봉우리 없음.
- ~~"rate resonance(특정 속도에서 나쁨)"~~ → 0.5G 스윕으로 반증, 전 구간 동전던지기.
- ~~"consumer 스케줄링 우선순위 / 서버 프로세스 메모리 레이아웃 / sender 버스트 구조"~~
  → 전부 bistable 진입 원인 아님으로 반증.
- ~~"예산에서 TCP 메모리를 빼야 한다"~~ → **측정으로 기각** (1코어 TCP+UDP 동시, N=3).
  합계가 어느 arm 이든 ~56G 로 **CPU 포화**다. 버퍼 크기는 둘 사이 **분배만** 바꾼다.
  | arm | UDP | TCP | 합계 |
  |---|---|---|---|
  | UDP 단독 | 39.99 | - | 39.99 |
  | 둘 다 자유 | 25.04 | 31.13 | 56.17 |
  | TCP 만 256K | 36.36 | 18.73 | 55.09 |
  | **UDP 만 1M 고정** | **21.08** | 37.20 | 58.28 |
  UDP 를 작게 묶으면 UDP 가 **더 나쁘다**(21.08 < 25.04). TCP 를 예산에서 빼는 것은
  정확히 그 arm 을 만드는 변경이므로 UDP 손실만 내고 합계 이득이 없다.
  (TCP 만 줄인 arm 하나로 판단할 뻔했다 — 규칙 6 의 전형적 함정)

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

### ★ 현행 커널: 6.18.53-udpopt4
`MLX5E_RX_MAX_HEAD 64` + `CONFIG_HARDENED_USERCOPY=n` + shed 기본 윈도 50us.
ring 128 / buf 1M / udp_blast→udp_sink 기준 (N=5):

| offered | shed off | shed on | busy(on) |
|---|---|---|---|
| 40G | 39.98 | 39.99 | 76% |
| 44G | 43.98 | 43.99 | 84% |
| 48G | 47.94 | 47.96 | 90% |
| 52G | 49.75 | 51.62 | 98% |
| 60G | 45.42 | **50.68** | 100% |
| 64G | 47.38 | **53.30** | 100% |

config 레버(MAX_HEAD+HARDENED)만으로 과부하 구간 **+9~11%**, 천장 아래 CPU −3%p.
6.6.9 에서는 overrun-bound 라 전환 안 됐던 것이 CPU-bound 가 되자 전환됐다.

### 다수 sender → 소켓 1개 (fan-in, `tools/udp_fanin.c`)
`udp_blast` 는 spin pacing 이라 sender 하나당 코어 하나가 필요하다. 한 프로세스가
N 소켓을 라운드로빈하는 `udp_fanin` 을 쓴다.

**sender 가 GSO 를 쓰면 흐름 수는 무의미하다.** GSO 가 선 위에 같은 흐름을 7개씩
연속으로 깔아서 GRO 가 여러 흐름을 동시에 붙들 필요가 없다 — 64 흐름에서도
merge 6.4 로 불변. 버킷 압력을 재려면 **`segs=1`** 로 인터리브시켜야 한다.

segs=1, 30G 고정: merge 6.6(1흐름) → 1.0(64흐름), busy 46% → 60% (+30% CPU).
sender 2코어로 천장을 넘기면 처리량이 실제로 무너진다:

| offered | flows=2 | flows=64 |
|---|---|---|
| 52G | 51.39 | 46.07 |
| 60G | 57.89 | **41.09** |
| 68G | 60.71 | **38.73** |

flows=2 는 계속 오르는데 flows=64 는 과부하에서 역으로 떨어진다 — shed 가 고치는
붕괴 모양과 같다. (무-GSO sender 는 1코어에서 42G 가 한계라 2코어가 필요)

### shed 윈도 (스윕 결과, 컨트롤러 불필요 판정)
| 윈도 | 52G | 60G | 72G |
|---|---|---|---|
| 끔 | 45.85 | 42.16 | 48.02 |
| 25us | 47.95 | 47.80 | 54.42 |
| **100us** | 49.38 | **48.60** | **56.61** |
| 200us | **51.82** | 47.65 | 52.88 |
| 1600us | 51.33 | **20.40** | **18.67** |

**비대칭**: 짧게 틀리면 −7%, 길게 틀리면 −67%. 부하 전환(72G→40G)에서는
1600us 가 shed 끔(17.3%)보다 나쁜 38.5% 손실.
-> 적응 컨트롤러 **불필요** (오라클 이득 +1.6%, 탐색 비용이 더 큼). 기본값 50us.

### 구 shed 효과 (6.18.53-udpopt2, N=10, udp_blast→udp_sink)
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

0009 버전 이력 (전부 같은 패치, 누적):
| ver | 내용 |
|---|---|
| v8 | 예산의 기준을 `sk_memory_allocated`(큐에 쌓인 양) → **나눠준 용량**으로. 전자는 소비자가 따라가면 거의 비어 있어 예산이 안 문다 |
| v9 | `SO_RCVBUF` 소켓을 **거절하지 않고 계상만**. 안 하면 그 소켓이 예산에 안 보여 나머지가 옆에서 계속 자란다 |
| v10 | **축소 경로** (성장 1/2 초과, 축소 1/8 미만, 4배 데드밴드). 래칫 해소 |
| v11 | 멀티코어 정합성: autotune 카운터 `cmpxchg`+`atomic_t`, shed 큐를 소켓 아닌 **패킷**에서, 유휴 grant 회수 워커, drained 게이트 |
| v12 | 목표값을 **유도**로 (`target = 2 × 비움주기 최대점유`, DRS 의 RTT 자리에 비움주기) + AI(+64KB). **level-trigger 버그로 실패** |
| v13 | 축소가 목표 존중. 원인이 아니어서 효과 없음 |
| v14 | 목표 갱신 **edge-trigger** (찼다가 비어야 주기 완성). W1 복구 |
| **v15 (현행)** | **버퍼 전체 1회 계상** (`cmpxchg(granted,0,rcvbuf)`) + 축소 바닥 `max(target, rmem_default)`. **autotune 단독으로 두 워크로드** |

**v11 이 고친 것 (둘 다 `combined 1` 이라 안 보였던 버그)**
- `udp_rcvbuf_autotune()` 은 `net/ipv4/udp.c` 에서 `spin_lock(&list->lock)` **앞**에
  호출된다 → 락 없음. sender 가 여럿이면 RSS 가 여러 큐로 뿌려 여러 코어 softirq 가
  같은 sk 에 동시 진입한다. `int` RMW 라 갱신 유실 → (1) 동시 doubling 으로 예산 2배
  초과, (2) per-socket 합 < global 합 → `udp_destruct_common()` 이 덜 반납 →
  **전역 카운터 영구 누적 → 예산 고갈 → 리부팅 전까지 어떤 소켓도 못 자람**
- `udp_rx_shed_mark()` 가 `sk_rx_queue_get(sk)` 사용 → unconnected 다중 sender
  소켓은 -1 을 돌려주고 fallback 이 `q = 0` 으로 바꿨다 → 멀티큐에서 **모든 shed 가
  큐 0 으로만** 간다. `skb_get_rx_queue()` 로 교체 (mlx5 가 `en_rx.c:1638` 에서 기록)

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
