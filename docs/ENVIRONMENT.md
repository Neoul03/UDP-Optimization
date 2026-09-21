# 실험 환경

## 하드웨어

| 항목 | 값 |
|---|---|
| CPU | Intel Xeon Silver 4310 @ 2.10GHz, 2 socket, 24 core |
| L2 / L3 cache | 30 MiB / **36 MiB** |
| NUMA | node0 = CPU 0-11, node1 = CPU 12-23 |
| NIC (실험용) | NVIDIA ConnectX-5 (`mlx5_core`), 100 Gbps, `ens81f0np0` |
| NIC (비교용) | Intel E810 (`ice`), 100 Gbps, `ens102f0np0` |
| MTU | 9000 (jumbo frame) |

## 노드

| 역할 | 호스트 | 실험 IP | 커널 |
|---|---|---|---|
| Receiver (server) | sslab4 | 192.168.11.238 | 6.6.9 계열 (변종 다수) |
| Sender (client) | sslab3 | 192.168.11.120 | 6.6.9 |

## 커널 변종

| LOCALVERSION | 내용 |
|---|---|
| `-vanilla` | stock 6.6.9 (`CONFIG_HARDENED_USERCOPY=y`) — baseline |
| `-nohardened` | `CONFIG_HARDENED_USERCOPY=n` (Tier 0 실험) |
| `-udpbatch` | patch 0003 + 0004 (lock/recv batching, negative result) |
| `-autotune` | patch 0006 (rcvbuf autotune) |
| `-udprx1` | 0006 + 0007 (socket-level early drop) |
| `-udprx2` | 0006 + 0007 + 0008 (driver-level RX shed) |

## "진짜 단일코어" 측정 방법론 (필수)

단일코어 측정은 방법론 오염에 극도로 취약하다. 아래를 **매 측정마다** 강제하고 검증한다.

```bash
# 1. irqbalance 영구 정지 (stop만으로는 부족 — 재부팅/재시작 시 IRQ를 다시 분산함)
sudo systemctl mask irqbalance

# 2. RSS 제거: RX 큐를 1개로 (이걸 안 하면 NAPI 코어가 4-tuple hash로 결정되어 핀이 무의미)
sudo ethtool -L ens81f0np0 combined 1

# 3. NIC MSI IRQ 전부 core1 고정 (set_irq_affinity 스크립트는 일부 IRQ를 놓칠 수 있음)
for irq in $(ls /sys/class/net/ens81f0np0/device/msi_irqs/); do
    echo 2 | sudo tee /proc/irq/$irq/smp_affinity
done

# 4. governor 고정 (미고정 시 결과가 크게 요동)
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance | sudo tee $g
done

# 5. MTU 재설정 — 재부팅하면 1500으로 리셋된다
sudo ip link set ens81f0np0 mtu 9000

# 6. consumer 프로세스도 같은 코어에
taskset -c 1 <server>
```

**검증**: `mpstat -P 1 1` 에서 core1에 `%soft`와 `%sys`가 **둘 다** 잡혀야 한다.
`%soft`가 0이면 NAPI가 다른 코어에서 도는 것이고 사실상 2코어 측정이다.

### 과거에 실제로 겪은 오염 사례

- `irqbalance`가 재부팅마다 IRQ 재분산 → "단일코어" TCP가 34~59G로 2배 요동
- `set_irq_affinity one 1`이 IRQ 1개를 `ffffff`로 남김 → 단일 flow가 그 큐를 쓰면 NAPI가 랜덤 코어로 float
- 재부팅 후 MTU 1500 리셋 → 전체 매트릭스 무효화
- SoftRoCE 측정 시 `rxe_wq`(unbound workqueue)가 별도 코어에서 실행 → 전역 unbound WQ cpumask도 고정 필요

## 벤치마크 도구

- `iperf3`: 수정판 (`patches/0005`) — TX GSO(`UDP_SEGMENT`) + RX GRO(`UDP_GRO` opt-in) 지원.
  RX GRO는 기본 ON이며 `IPERF3_UDP_GRO=0`으로 비활성화(A/B용).
- `tools/udp_blast.c`, `tools/udp_sink.c`: 경량 송수신기 (iperf3 오버헤드 배제용)
- `tools/af_xdp_sink.c`: AF_XDP zero-copy 수신기 (상한 실증용)

## 알려진 측정 이슈

- **sender rate cap flake**: sender가 간헐적으로 요청 rate 대신 ~29.4 Gbps에 머무는 현상 (누적 10회 이상 관측).
  `tx` 값이 요청치의 97% 미만이면 해당 샘플을 무효 처리하고 재시도해야 한다.
  (`scripts/sweep_static_rcvbuf.sh`에 자동 재시도 구현)
- **mpstat ramp 편향**: 트래픽 시작 전 구간이 평균에 섞이면 busy%가 과소 계상된다. 앞 3-4 샘플을 버릴 것.
