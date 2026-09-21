# Daily Note — 2026-06-08

**주제: UDP 연구 종료 → SoftRoCE/RoCE 복귀, SoftRoCE 송수신 병목의 코드-레벨 규명**

---

## 0. 배경 / 오늘의 목표

- UDP RX 연구는 결론남: "DIM ON 폭락"은 대부분 artifact(`-l 9000` fragmentation + NIC IRQ 핀 누락)였고, 진짜 레버는 **app-layer UDP_GRO**. 제대로 핀하면 single-core UDP≈TCP≈44G.
- 원래 연구(UE→Edge GPU 서버로 RDMA direct data, SoftRoCE 기반)로 복귀. SoftRoCE도 UDP 기반이라 UDP anomaly를 파던 것.
- **오늘 목표**: 같은 sslab3/sslab4, 같은 mlx5 CX5 NIC/IP에서 (1) HW RoCE vs SoftRoCE 속도 측정, (2) SoftRoCE 병목을 코드+실험으로 규명, (3) "SoftRoCE에서 UDP GRO가 켜지는가" 확인.

---

## 1. 환경

| 항목 | 값 |
|---|---|
| 서버 | sslab4 = receiver (192.168.11.238), sslab3 = sender (192.168.11.120) |
| NIC | `ens81f0np0` = NVIDIA ConnectX-5 (mlx5_core, 100G) |
| 커널 | sslab3 = `6.6.9`, sslab4 = `6.6.9-udpbatch` (서로 다름!) |
| 링크 | 100 Gb/sec (4X EDR), netdev MTU 9000, RDMA active_mtu 4096 |
| HW RoCE 디바이스 | `rocep23s0f0` (양쪽), RoCEv2 IPv4 GID = **index 3** |
| Soft RoCE 디바이스 | `rxe0` (rdma_rxe 모듈), RoCEv2 IPv4 GID = **index 1** |
| 측정 도구 | `ib_write_bw` (perftest), RC, RDMA_WRITE |

주의: GID idx 2=IB/RoCE v1, idx 3=RoCE v2 (IPv4). soft rxe0는 idx 0=v2(link-local), idx 1=v2(IPv4).

---

## 2. 헤드라인 측정 — HW RoCE vs SoftRoCE

`ib_write_bw -d <dev> -F --report_gbits -D 10 -s 1048576 -q 4` (sslab3→sslab4)

| 구성 | BW |
|---|---|
| **HW RoCE** (RoCEv2, `rocep23s0f0`) | **97.31 Gbps** (라인레이트 포화) |
| **Pure SoftRoCE** (rxe↔rxe) | **14.96 Gbps** |
| **비대칭** (Soft 송신 → HW 수신, single) | 14.54 Gbps |

→ SoftRoCE 단일 ≈ HW의 1/6.5. (이게 오늘 파고든 대상)

---

## 3. ⚠️ 함정: rxe ↔ mlx5_ib 같은 포트 공존 불가

- mlx5_ib(HW RoCE verbs)가 떠 있으면 들어오는 RoCEv2 **UDP/4791을 HW 엔진이 가로채** SW rxe로 안 올림.
- 증거: 송신 `sent_pkts=77916`인데 수신 `rcvd_pkts=0`, 송신 `completer_retry_err` 폭증, BW=0.
- **해결**: 그 포트에서 `sudo rmmod mlx5_ib` (usecount 0, 안전; netdev/IP는 mlx5_core라 유지). 복구는 `sudo modprobe mlx5_ib`.
- 즉 SoftRoCE 측정 = 양쪽 mlx5_ib 내린 상태, HW RoCE 측정 = mlx5_ib 로드 상태. 둘 동시 불가.

---

## 4. SoftRoCE에서 UDP GRO가 동작하는가? → **실질적으로 아니오**

### 코드 (a: 직접 확인)
- `rxe_net.c:196-200` `rxe_setup_udp_tunnel`: UDP tunnel 소켓에 **`encap_rcv`만** 설정, `gro_receive`/`gro_complete`는 NULL. 소켓 GRO_ENABLED 비트도 안 켬(앱의 `setsockopt(UDP_GRO)` 없음).
- `udp_offload.c:558` `udp_gro_receive`: sk는 잡히나 `gro_receive`가 NULL → iperf3가 탔던 tunnel/socket GRO 경로 **안 탐**.
- 단, netdev에 `rx-gro-list`(NETIF_F_GRO_FRAGLIST), `rx-udp-gro-forwarding` 둘 다 ON(이전 UDP 실험 잔재) → 559~564행에서 `is_flist=1`로 **generic fraglist-GRO 경로는 engage 가능**.

### 실측 토글 (a) — q=4 soft↔soft, 수신측
| | BW | 수신 core1 softirq |
|---|---|---|
| rx-gro-list ON | 15.66 G | 35.2% |
| rx-gro-list OFF | 14.54 G | 37.9% |

차이 ~2.7%p / ~1G = **노이즈 수준**. fraglist-GRO가 rxe 패킷에 실질 coalescing 이득 없음.

### 근본 이유
iperf3 UDP_GRO 승리는 "datagram 다수 merge → 큰 copy 1회"였지만, **RoCE는 패킷마다 IB transport 헤더(BTH/PSN)가 달라 merge 자체가 불가**. GRO 레버가 RoCE엔 구조적으로 없음. (TX쪽 GSO도 동일 — 패킷마다 PSN/ICRC라 SW로 amortize 불가. HW RoCE는 이걸 하드웨어로 함 → 97G.)

---

## 5. SoftRoCE 병목 규명 (가설 → 배제의 여정)

> 결론부터: 처음엔 sender-bound로 오판하고 여러 후보를 팠으나 전부 red herring. **진짜 멀티-flow 캡은 수신측 IRQ 단일코어 핀**이었음.

### 5.1 QP 스케일링 (q=1~16, single process)
모두 ~15G 고정, q16=13.4G 하락. 매번 코어 1개만 ~91% (전부 `%usr` = **perftest CQ busy-poll 스핀, 실작업 아님**). 커널 rxe work는 여러 코어 분산, 포화 없음.

### 5.2 메시지 크기 스윕 → per-packet rate 천장 ~480 Kpps
`-s` 스윕 (q1, t128), wire pps = msgrate × ⌈s/4096⌉:

| msg | BW | wire pps |
|---|---|---|
| 4 KB | 6.33 G | 0.19 Mpps |
| 16 KB | 10.41 G | 0.32 Mpps |
| 64 KB | 15.68 G | **0.48 Mpps** |
| 256 KB | 16.04 G | 0.49 Mpps |
| 1 MB | 15.73 G | 0.48 Mpps |
| 4 MB | 15.10 G | 0.46 Mpps |

→ msg≥64KB에서 **pps가 ~0.48M로 포화** → BW 15~16G 평탄. 근본 한계는 대역폭 아니라 **패킷 처리율**.

### 5.3 tx-depth 스윕 (s=64K)
t2=9.0G → t8=11.3G → **t32=15.0G → t128=15.8G 포화**. tx_depth<32만 window-bound, ≥32부터 pps 천장이 지배.

### 5.4 병렬 프로세스 (공유 천장 확인)
1proc=15.7G / 2proc=8.8×2=17.6G / 4proc=3.77×4=15.1G → 거의 안 늚 = **공유 천장**.

### 5.5 off-CPU 분석 (bpftrace, single-QP) → skb 윈도우
- requester는 `done:`(ret=0 계속) / `exit:`(ret=-EAGAIN=-11 정지). (`rxe_req.c:868-879`)
- 정지 gap 분해: **73% self-requeue = skb-TX 백프레셔**(completer 없이 자기 재큐), 27% ACK-window 대기(~8-16us), 그 후 wq 재디스패치 ~2-4us.
- **메커니즘**: `qp->skb_out > RXE_INFLIGHT_SKBS_PER_QP_HIGH(=64)` 면 정지 (`rxe_req.c:750`). skb가 NIC TX완료로 free될 때 `rxe_skb_tx_dtor`(`rxe_net.c:346`)가 skb_out 감소, `<LOW(=16)`면 재기상. 하드코딩 윈도우(64/16, `rxe_param.h:112-113`).
- 관찰자 효과 주의: bpftrace가 400K/s 추적 → 처리량 하락, 절대율 비신뢰. path-split(73/27)은 robust.

### 5.6 rxe 모듈 리빌드 — 윈도우 스윕 → 부분 요인(+15%)
송신측(sslab3)만 리빌드(`/usr/src/linux-6.6.9`, in-tree `make M=...`), 수신 stock 유지.

single-QP:
| HIGH/LOW | BW |
|---|---|
| 64/16 (stock) | 15.38 G |
| 256/64 | **17.62 G (+15%)** |
| 1024/256 | 17.48 G |
| 4096/1024 | 17.62 G |

윈도우 256에서 포화(+15% 후 plateau). **multi-QP/4proc는 큰 윈도우에서도 ~15G** → 윈도우는 single-QP 한정 부차적 요인. 공유 천장은 별개.

### 5.7 perf lock + recv_sockets.sk4 → 둘 다 배제
- perf record(4-flow): `_raw_spin_lock` ~1%만, `queued_spin_lock_slowpath`/`osq_lock` 부재 → **lock-bound 아님**.
- bpftrace 함수율(/s): **송신** requester 411K, encap_recv(sk4)=**6.2K**(ACK, 극소). **수신** encap_recv(sk4)=392K(data) but 수신 코어 여유. → **recv 소켓도 병목 아님**.

### 5.8 rxe_wq workqueue 플래그 → 배제
`alloc_workqueue("rxe_wq", FLAGS, WQ_MAX_ACTIVE)` (`rxe_task.c:13`) 변형:
| flags | single | 4-flow |
|---|---|---|
| WQ_UNBOUND (stock) | 16.36 G | 15.08 G |
| 0 (bound/percpu) | 15.52 G | 15.30 G |
| WQ_UNBOUND\|WQ_HIGHPRI | 15.73 G | 14.88 G |

전부 4-flow ~15G → **워크큐 플래그 무관**. ICRC도 배제(`SHASH_DESC_ON_STACK` per-call 스택, `rxe_icrc.c:48`).

### 5.9 ★ 돌파구 — asymmetric 4-flow
| 구성 | 4-flow 집계 |
|---|---|
| soft → soft | 15.08 G |
| **soft → HW** | **48.50 G (스케일!)** |

→ **송신측 rxe는 4 flow로 48G까지 멀쩡**. soft→soft 15G 캡은 **수신측 rxe**였다. (이전 "sender-bound"는 single-flow 한정 오판 — single은 단일 requester ~15G에 막혀 우연히 겹친 것.)

### 5.10 ★ 진범 — 수신측 RX IRQ 단일코어 핀
- soft→soft 4-flow시 RX 큐는 RSS로 **잘 분산**(rx1/14/15/17 각 1.39M, ethtool udp4 해시 sdfn 정상) 인데, **softirq는 core 1만 66.6%, 나머지 idle**.
- 원인: **NIC IRQ 50개 중 26개가 CPU 1에 핀** — lab baseline `set_irq_affinity one 1`(UDP 단일코어 실험 잔재)이 모든 RX 큐 NAPI를 core 1로 직렬화.
- **검증**: 수신 IRQ를 24코어 round-robin 분산 → soft→soft 4-flow **15.08G → 41.12G (2.7배)**, softirq가 4코어(21,23,1,4) 각 66%로 분산.

**→ 멀티-flow 캡은 rxe 코드가 아니라 운영 설정(IRQ 핀)이었다.**

---

## 6. 영구 IRQ 분산 + 스케일링 곡선

### 영구 적용 (sslab4)
- systemd oneshot `spread-rxe-irqs.service` (enabled, 부팅 생존):
  - `/usr/local/sbin/spread-rxe-irqs.sh` → `ens81f0np0` msi_irqs(25개)를 24코어 round-robin 분산
  - irqbalance는 inactive (충돌 없음)
- **이제 sslab4 RX IRQ는 24코어 분산이 기본.** ⚠️ UDP 단일코어 실험 재현시 `sudo systemctl stop spread-rxe-irqs` 후 재핀 필요.

### SoftRoCE soft→soft 스케일링 곡선 (독립 프로세스 N개, s=1M)
| flows | 집계 BW | per-flow |
|---|---|---|
| 1 | 15.5 G | 15.5 |
| 2 | 25.0 G | 12.5 |
| 4 | 32.6 G | 8.1 |
| 8 | 44.0 G | 5.5 |
| **12** | **49.9 G (peak)** | 4.2 |
| 16 | 44.5 G | 2.8 (하락) |

- **단일코어 핀 15G → 멀티-flow 50G (3.3배)**.
- Sublinear (per-flow 15.5→4.2G 감소) — SW rxe per-packet CPU 비용 누적.
- N=16 하락 = 송신측 24코어 oversubscription (perftest 클라이언트 16개 busy-poll + requester wq 경합). N≈12가 24코어 셋업 스윗스팟.
- peak ~50G = HW 97G의 절반 (SW 고유 한계). **단, busy-poll 클라이언트가 코어 낭비하므로 부분적 perftest 아티팩트** — event-driven 앱이면 더 높을 여지.

---

## 7. 최종 결론

1. **HW RoCE 97G vs SoftRoCE single 15G**: SoftRoCE는 패킷마다 SW로 skb 할당 + ICRC(CRC32) + IP스택 통과. RoCE 의미상 패킷마다 BTH/PSN이라 **GRO/GSO로 amortize 불가** (HW는 이걸 하드웨어 파이프라인으로).
2. **single-flow 15G** = 단일 rxe requester의 SW rate 한계 (~480 Kpps).
3. **멀티-flow 집계 캡 15G의 진범** = **수신측 RX IRQ 단일코어 핀** (코드 아님). IRQ 분산이 핵심 레버 → 50G.
4. **Red herrings (전부 배제)**: 단일 TX큐(XPS), per-QP skb윈도우(부분만), rxe_wq 플래그, spin-lock, `recv_sockets.sk4`, ICRC.
5. **실용 가이드**: SoftRoCE 멀티-flow 가속 = 수신측 NIC IRQ 멀티코어 분산 (rxe 코드 수정 불필요). single-flow 한계는 멀티-flow로 회피.

---

## 8. 재현용 명령/파일 (오늘 만든 것)

### sslab3 (sender)
- `/tmp/rxe_reload.sh HIGH LOW` — rxe_param.h 윈도우 수정+리빌드+모듈 교체
- `/tmp/rxe_wq_reload.sh "FLAGS"` — rxe_task.c wq 플래그 수정+리빌드+교체
- 백업: `/usr/src/linux-6.6.9/drivers/infiniband/sw/rxe/{rxe_param.h,rxe_task.c}.orig` (현재 stock 복원됨)
- bpftrace: `/tmp/offcpu2.bt` (off-CPU 분해), `/tmp/rate.bt` (함수율)
- 빌드트리: `/usr/src/linux-6.6.9` (vermagic 6.6.9, modversions on)

### sslab4 (receiver)
- `/usr/local/sbin/spread-rxe-irqs.sh` + `/etc/systemd/system/spread-rxe-irqs.service` (enabled, **영구**)
- `/tmp/rate.bt`

### 핵심 명령 템플릿
```bash
# soft RoCE 측정 모드 (양쪽)
sudo rmmod mlx5_ib; sudo rdma link add rxe0 type rxe netdev ens81f0np0
# HW RoCE 복구
sudo modprobe mlx5_ib
# HW server/client (rdma_cm)
ib_write_bw -d rocep23s0f0 -F --report_gbits -R -D 10 -s 1048576 -q 4 [192.168.11.238]
# soft server/client (-x로 v2 GID 명시)
ib_write_bw -d rxe0 -F --report_gbits -D 10 -s 1048576 -t 128 -q 1 -x 1 [192.168.11.238]
# 수신 IRQ 분산 (영구는 systemd, 수동은)
for irq in $(ls /sys/class/net/ens81f0np0/device/msi_irqs/); do ...round-robin...; done
```
주의: `ssh <h> "...pkill -f ib_write_bw..."`는 자기 명령줄 매칭으로 셸 자살(ssh 255) → 패턴 `'[i]b_write_bw'` 사용. 백그라운드 ssh 직후 또 ssh면 control socket wedge → `ssh -O exit` + `rm -f ~/.ssh/cm-*`.

---

## 9. 현재 상태 (세션 종료 시점)
- 양쪽 **HW RoCE `rocep23s0f0` ACTIVE**, mlx5_ib 로드됨 (기본).
- sslab3 rxe = stock(64/16, WQ_UNBOUND) 복원.
- **sslab4 IRQ 분산 영구 적용 (systemd enabled)** — 과거 core1 단일핀 baseline과 달라짐.
- 잔여 프로세스 0.

---

## 10. 다음 단계 후보
- **(a)** event-driven 수신(busy-poll 제거, `ibv_get_cq_event` 기반)으로 perftest 아티팩트 없는 진짜 SoftRoCE 천장 측정.
- **(b)** 원래 목표: **GPUDirect / edge ML 셋업** — HW RoCE 97G + GPU 메모리 직접(`ib_write_bw --use_cuda` 가능 여부, peermem/CUDA 확인).
- **(c)** UE=SoftRoCE(50G) → Edge=HW RoCE(97G) 비대칭을 실제 ML 데이터 패턴으로 실측.

---

## 11. sslab4 커널 통일 (udpbatch → vanilla 6.6.9)

변수 제거를 위해 sslab4를 `6.6.9-udpbatch`(UDP consumer-batch 패치 커널)에서 **vanilla `6.6.9`** 로 전환 (sslab3와 동일).

- sslab4엔 6.6.9 계열 다수 설치돼 있었음: `6.6.9`(Jan15, "stock"), `6.6.9-vanilla`(Jun4 재빌드), `6.6.9-udpbatch`(패치). → **`6.6.9` 선택** (sslab3와 uname-r 일치).
- GRUB 기본값이 이미 `6.6.9`를 가리켰으나 리부트 전이라 udpbatch가 돌고 있던 것.
- **안전 전환(one-shot)**: `GRUB_DEFAULT=saved`, `saved_entry=udpbatch`(fallback), `grub-reboot 6.6.9`(다음 1회) → 리부트 → 6.6.9 부팅 확인 후 `grub-set-default 6.6.9`(영구화). 백업: `/etc/default/grub.bak`.
- 리부트 소요 ~3.5분. 복귀 후 `uname -r=6.6.9` (#1 SMP Jan15 2025).
- **리부트로 드러난 비영구 항목 2개**:
  - **MTU**: 9000→1500 리셋됨 (netplan에 MTU 없음, 양쪽 다 수동 적용 관례). → `ip link set ens81f0np0 mtu 9000` 재적용. sslab3도 리부트하면 동일하게 1500되니 실험 전 항상 확인할 것.
  - **IRQ 분산**: systemd 서비스가 부팅 시 IRQ 지연할당으로 12코어만 잡음 → `ExecStartPre=/bin/sleep 20` + `After=network-online.target` 추가해 보강(이제 24코어).
- 검증: 양쪽 kernel=6.6.9, MTU=9000, RoCE ACTIVE 패리티. **HW RoCE 새 커널에서 98.15 Gbps** 정상.
- GRUB 영구 기본값 = `6.6.9` (`saved_entry`). 향후 udpbatch 필요시 `grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux 6.6.9-udpbatch"`.

**현재 양 서버 완전 패리티: kernel 6.6.9 / MTU 9000 / RoCE rocep23s0f0 ACTIVE.**

---

## 12. RDMA transport 심화 — 지연(latency) 특성 (ML 동기화 관점)

> GPUDirect 셋업은 **양 서버에 GPU가 없어 불가**(ASPEED 온보드만, NVIDIA/CUDA/peermem 전무) → RDMA transport 연구 심화로 방향 전환. 지금까지 BW만 봤고 latency 공백을 메움.

`ib_write_lat -F -s <B> -n 20000` (one-sided RDMA WRITE, usec)

### WRITE 지연: HW RoCE vs SoftRoCE (idle)
| bytes | HW typ | HW p99 | HW p99.9 | Soft typ | Soft p99 | Soft p99.9 |
|---|---|---|---|---|---|---|
| 8 | 1.16 | 1.18 | 2.22 | 13.18 | 26.09 | 35.5 |
| 64 | 1.16 | 1.29 | 2.30 | 13.42 | 26.51 | 53.7 |
| 512 | 1.90 | 2.05 | 3.05 | 12.99 | 33.10 | 84.0 |
| 4096 | 2.97 | 3.16 | 4.06 | 17.75 | 40.87 | 74.9 |

- **HW RoCE**: ~1.16us typical(소형), tail 극히 tight(p99.9 ~2us, typ의 ~2배). 하드웨어 = 결정론적.
- **SoftRoCE**: typical ~13us(**HW의 11배**), 게다가 **tail이 HW의 ~20배**(p99.9 35~84us). softirq 스케줄 + workqueue 디스패치 jitter.
- ML 함의: 동기식 분산학습(AllReduce 배리어)은 **제일 느린 링크가 매 스텝을 gate** → SoftRoCE의 ~84us tail이 학습 스텝 시간을 지배. BW보다 tail-latency가 더 치명적일 수 있음.

### 비대칭 WRITE 지연: UE(soft sslab3) → Edge(HW sslab4)
| bytes | typ | p99 | p99.9 |
|---|---|---|---|
| 8 | 5.86 | 6.87 | 16.2 |
| 512 | 6.05 | 6.87 | 16.7 |
| 4096 | 7.18 | 8.01 | 8.9 |

→ pure soft(13us/84us)와 pure HW(1.2us/2us)의 **중간**(~6us/~16us).

### ★ BW vs Latency 대비 (배포 설계 핵심)
| 지표 | soft→soft | **비대칭 soft→HW** | HW→HW |
|---|---|---|---|
| per-flow BW | ~12-15G | ~12-15G (변화 없음) | line-rate |
| typ latency | ~13us | **~6us (절반)** | ~1.2us |
| p99.9 latency | ~84us | **~16us (1/5)** | ~2us |

- **Edge에 HW RoCE를 두면**: peak BW엔 의미 없음(UE 송신 SW TX가 BW 캡) but **지연·tail엔 매우 유효**(수신측 SW 지연/jitter 제거로 typ 절반, tail 1/5).
- 즉 UE=SoftRoCE(commodity, GPU/HW 없음) + Edge=HW RoCE 구성은 **동기식 ML 지연 측면에서 합리적** — UE의 BW 한계(~15G/flow, 멀티-flow 50G)는 남지만 latency는 Edge HW가 크게 보전.

### Limitation / 다음
- idle 지연만 측정. **부하 중 지연**(tensor BW 트래픽과 control 혼재 시 jitter 폭증 예상)은 미측정 — ML 실제 패턴에 가장 가까운 다음 실험.
- two-sided `ib_send_lat`(메시지/제어 패턴), `ib_read_lat` 미측정.
- 로그: sslab3 `/tmp/{hwlatc,swlatc,aslatc}_<size>.log`.

---

## 13. ★ SoftRoCE 성능 최적화 — TCP 타겟, 갭의 본질 규명

목표: SoftRoCE를 어디 고치면 빨라지나, TCP 수준 도달 가능한가? (6.6.9, IRQ분산, MTU9000)

### 비교표 (throughput)
| | single stream/flow | multi (4) |
|---|---|---|
| HW RoCE | 97 G | ~97 G |
| **TCP** (iperf3) | **38.3 G** | **90.8 G** |
| SoftRoCE | 16.5 G | 32.6 G (peak 50G@12flow) |

### ★ 핵심 발견: 갭의 본질 = MTU(패킷 크기), per-packet 효율 아님
- TCP single을 **GSO/TSO/GRO OFF** 하니 38.3→**36.7G** (거의 안 떨어짐) → TCP single은 stack-CPU/offload-bound 아님.
- **패킷률 환산**: TCP no-offload = 36.7G÷9000B = **510 Kpps**, SoftRoCE single = 16.5G÷4096B = **505 Kpps**. → **둘 다 single-flow ~505 Kpps로 동일**.
- 즉 SoftRoCE가 느린 이유는 처리 효율이 아니라 **RoCE MTU 4096B vs Ethernet MTU 9000B = 2.2배 bytes/packet 핸디캡**. 같은 패킷률인데 패킷이 절반.

### MTU cap 위치 (코드)
- `rxe.c:159`: `mtu = mtu ? min_t(enum ib_mtu, mtu, IB_MTU_4096) : IB_MTU_256;` — netdev 9000이어도 **rxe가 IB_MTU_4096으로 강제 cap**.
- `enum ib_mtu` 표준 최대 = `IB_MTU_4096=5` (ib_verbs.h:455, 8192 enum 없음). libibverbs IBV_MTU도 4096 cap.
- **rxe는 순수 SW라 이 cap을 올릴 수 있음** → 단 IB enum(코어 헤더)+rxe+libibverbs(rdma-core)+perftest 4계층 패치 필요, 비표준(rxe↔rxe 전용, HW RoCE와는 호환 안 됨).

### per-packet 비용 분해 (perf, single-flow 송신 커널, 6.6.9)
- `__alloc_skb`+kmalloc ≈ **11.5%** (패킷마다 skb 할당 — 최대 단일 비용)
- `rxe_xmit_packet` 15% (ip_local_out→ip_output→dev_queue_xmit), `rxe_init_packet` 13%, ICRC 7.5%
- ICRC는 이미 **crc32-pclmul(HW PCLMULQDQ 가속)** 백엔드 → 쉬운 lever 아님.

### 최적화 lever 랭킹
1. **★ MTU cap 상향 (rxe.c:159, 4096→8192)** — 최대 lever(~1.7-2.2배 single-flow). cross-layer 패치 필요, 비표준 rxe-only. **single-flow가 TCP에 닿을 유일한 길.**
2. **skb 풀링/recycling** — ~11.5% per-packet 비용 절감(single-flow ~16.5→18G). rxe-local 패치, 중간 난이도. multi-flow aggregate엔 더 효과(코어 효율↑).
3. RXE_INFLIGHT_SKBS 윈도우 (이미 +15% 확인), IRQ분산(이미 적용, multi-flow 50G).

### TCP-parity 판정
- **single-flow**: micro-opt(skb풀+윈도우)만으론 ~20G가 한계 (TCP 38G 못 닿음). **MTU 상향이 필수** — 8192 MTU면 ~28-33G로 TCP single 근접 가능(가설, 검증 필요).
- **multi-flow**: SoftRoCE 50G vs TCP 91G. per-packet 비용 절감 + 코어 스케일 + perftest busy-poll 아티팩트 제거하면 line-rate 근접 여지.
- **결론**: SoftRoCE의 single-flow TCP-parity는 "더 큰 패킷(MTU)"이 핵심이고, 이는 SW rxe라서 가능하나 비표준 cross-layer 패치가 필요한 research-grade 작업. 미세 최적화로는 격차의 절반도 못 메움.

### 다음 (이 방향)
- **(우선) MTU 8192 실험**: IB enum + rxe + rdma-core + perftest 패치 후 rxe↔rxe single-flow 측정 → MTU 가설(2배 가설) 검증. 양 서버 다 6.6.9라 가능(빌드트리 확인 필요).
- skb 풀링 프로토타입(rxe-local, 빠른 win).

---

## 14. ★★ MTU 8192 rxe 패치 — 구현 & 측정 (가설 검증 성공)

### 빌드 환경 (확인)
- 양 서버 `/usr/src/linux-6.6.9` 빌드트리 완비. rxe 3파일 byte-identical(md5 동일).
- **패치 범위 = rxe-local만** (당초 4계층 우려 → 1계층). 근거: `enum opa_mtu`에 OPA_MTU_8192=6 기존재 / ib_core·uverbs는 path_mtu 무검증 통과(`uverbs_cmd.c:1850`) / 변환·청킹 전부 rxe-local(`eth_mtu_int_to_enum`=rxe_param.h, payload=qp->mtu int).

### 패치 (rxe-local 3파일, 값 6 = 8192 사용)
- `rxe_param.h`: `rxe_mtu_int_to_enum`에 `mtu<8192→4096, else→(enum)6` 추가 + `rxe_mtu_enum_to_int`(6→8192) 헬퍼 신설.
- `rxe.c:82`: `max_mtu = IB_MTU_4096` → `(enum ib_mtu)6`. `rxe_set_mtu`(159): `min_t(...,IB_MTU_4096)` → `...,(enum)6`; mtu_cap은 새 헬퍼.
- `rxe_qp.c:703`: `qp->mtu = ib_mtu_enum_to_int(path_mtu)` → 새 헬퍼.
- RXE_MAX_HDR_LENGTH=80이라 netdev 9000 → 9000-80=8920≥8192 → active_mtu enum 6.
- 백업 `.mtu8192bak`, 패치 .ko = `/usr/src/linux-6.6.9/drivers/infiniband/sw/rxe/rdma_rxe.ko`(양쪽).

### 검증 (성공)
- `ibv_devinfo`: active_mtu = `invalid MTU (6)` ← libibverbs가 enum6 문자열만 모름, **값 6=8192 정상**.
- **perftest가 포트 active_mtu=8192 자동 채택** (`Mtu: 8192[B]`) → **유저스페이스(rdma-core/perftest) 패치 불필요**.

### 결과 (s=1M, t=256, IRQ분산)
| | @4096 | **@8192** | 증가 |
|---|---|---|---|
| single-flow | 16.5 G (505 Kpps) | **22.4 G (342 Kpps)** | **+36%** |
| 4-flow agg | 32.6 G | **62.5 G** | **+92%** |

- single은 +36%뿐(2배 안 됨): pps 505→342K, 패킷 2배 커지며 copy+CRC(가변비용 ~절반)도 2배 → 고정비용만 amortize.
- **multi-flow는 +92%(거의 2배)**: 4096에서 aggregate pps-bound였는데 8192는 같은 pps에 2배 데이터. → TCP 4-stream(90.8G) 대비 36%→**69%로 갭 축소**.

### TCP-parity 재평가
- single-flow: 22.4G (TCP 38G의 59%). MTU+윈도우+skb풀 조합시 ~25-28G 여지. 완전 parity는 아직.
- **multi-flow: 62.5G@4flow (TCP 91G의 69%)**. 코어 더 쓰면(8flow+) line-rate 근접 가능 — TCP-parity 현실적.
- 결론: **MTU가 진짜 lever 맞음(검증됨)**. multi-flow에서 특히 효과적. rxe는 SW라 비표준 MTU 가능(rxe↔rxe 전용, HW와는 4096).

### 스케일링 곡선 @8192 (N flow, IRQ 양쪽 24코어 분산)
| flows | @4096 | **@8192** |
|---|---|---|
| 1 | 15.5 G | 22.4 G |
| 2 | 25.0 G | 34.7 G |
| 4 | 32.6 G | 62.1 G |
| 8 | 44.0 G | 69.9 G |
| **12 (peak)** | 49.9 G | **74.8 G** |
| 16 | 44.5 G | 72.9 G |

- **멀티-flow peak: 50G(@4096) → 74.8G(@8192)** = **TCP 4-stream(90.8G)의 82%** (4096 땐 55%).
- N=12 이후 plateau/하락 = 송신 24코어 oversubscription(perftest busy-poll 16개) + SW per-packet 비용. → 진짜 천장(~75G)은 SW rxe per-packet CPU + 측정 아티팩트.
- **TCP-parity 판정(갱신)**: 멀티-flow는 **82%까지 도달**, busy-poll 제거(event-driven) + skb풀 + 코어 효율 개선이면 line-rate(97G) 근접 현실적. single-flow는 22G(TCP38G의 59%)로 여전히 갭.

### 다음
- MTU 8192 + 윈도우(RXE_INFLIGHT_SKBS 256) 조합.

---

## 15. TX/RX 비대칭 — HW를 어느 쪽에 두면 도움되나 (single-flow, MTU4096)

2×2 매트릭스 (goodput):
| | RX=soft | RX=HW |
|---|---|---|
| TX=soft | ~15G (jittery 12.6~17) | **~21G (안정)** |
| TX=HW | **0.84G (붕괴)** | 98G |

- **HW RX가 soft TX를 +40% & 안정화**. 처음 단발 측정서 soft→HW(15.3)<soft→soft(16.5)로 반대로 보였으나, **back-to-back + interleaved A/B**로 soft→HW(~21G) > soft→soft(~15G) 확정. single-flow soft RoCE는 latency-bound라 run간 변동 큼 → 비교는 반드시 나란히.
- **메커니즘**: soft TX는 latency/window-bound(코어58%, ACK/completion 대기). HW RX는 즉시 처리 + HW ACK(결정론적) → 완료 round-trip 단축 → soft TX window가 빠르고 매끄럽게 전진. soft RX는 SW ACK+처리로 루프에 지연·jitter 추가. **HW RX가 ACK를 빨리 돌려줘 soft TX stall을 줄임.**
- **HW TX → soft RX = 0.84G 붕괴**: HW가 flood → soft RX drop → go-back-N 재전송 폭주(`duplicate_request +206K`, RX core 54%로 CPU 한가). soft TX는 self-pace(graceful), soft RX는 과부하시 catastrophic.
- 함의: **UE=soft TX → Edge=HW RX**가 처리량·지연·tail·안전 다 이득. 이후 실험 RX=HW 고정.

---

## 16. ★★ page_pool TX 버퍼 재활용 패치 — 구현 & 측정 (성공)

### 동기 (프로파일 재해석)
zero-copy로 가려다 perf 보니 **복사는 5%뿐, 진짜 비용은 8KB 버퍼 alloc(22%)+free(12%)=34%**. → 복사 frag화(ICRC 수술, 위험) 대신 **버퍼 재활용**(패킷 byte-identical, HW RX 호환 보장, 저위험)으로 34% 공략.

### 패치 (rxe-local 6파일, 송신측 sslab3만; RX=HW라 TX만 패치)
- per-QP `struct page_pool *pp` (rxe_verbs.h) → `rxe_qp_init_req`에서 `page_pool_create`(order=1/8KB, pool_size=256, flags=0 no-DMA), `rxe_qp_do_cleanup`에서 destroy.
- `rxe_init_packet`(rxe_net.c): qp 인자 추가, `page_pool_alloc_pages`+`build_skb`+`skb_mark_for_recycle`로 payload 버퍼 재활용(paylen>256 & fit시), 실패시 alloc_skb fallback. 호출자 2곳(rxe_req.c:434, rxe_resp.c:779)+선언(rxe_loc.h) 수정.
- TX완료(napi_consume_skb)시 페이지가 pool로 자동 환원 → per-packet 8KB kmalloc/free 제거.
- 빌드 OK, **HW RX 정상 수신(correct), dmesg 무경고/무패닉**. (MTU 8192 패치도 같은 모듈에 있으나 RX=HW라 4096 negotiate→dormant.)

### 결과 (interleaved A/B, soft TX→HW RX, MTU4096)
| | stock | **page_pool** | 효과 |
|---|---|---|---|
| single-flow | ~20 G | **~26 G** | **+30%** |
| 4-flow agg | ~49 G | ~52 G | +6% |

- single-flow +30%: alloc/free churn(34%) 제거가 latency-bound requester를 직접 가속. → TCP single(38G)의 68%.
- 4-flow +6%: ~50G 다른 천장(soft TX→HW RX aggregate)에 근접해 alloc 절감 효과 희석.

### 다음
- (선택) frag zero-copy로 나머지 copy 5% + alloc 추가 절감.
- page_pool + MTU 8192 stack: RX도 8192 가능해야(soft↔soft) 의미. RX=HW면 dormant.
- 패치 .ko: sslab3 `/usr/src/.../rdma_rxe.ko` (page_pool+MTU8192 결합), 백업 `.ppbak`. 재로드: rmmod+insmod. 복구: modprobe stock.

### page_pool 후 single-flow 프로파일 (max single-flow 분석)
- requester 코어 **78.6% sys**(스톡 58%→상승) = page_pool로 per-packet 싸져 **CPU-bound 근접**.
- 남은 비용: **IP스택 10%**(ip_local_out~ip_finish_output2; dst는 `rxe_find_route` rxe_net.c:100서 QP소켓에 이미 캐시→redundant 아님, 실제 IP처리라 줄이기 어려움), **memcpy(copy) 6%**, TX완료 10%, build_skb 3%(alloc 22%→3%!), ICRC 1.5%.
- **window(RXE_INFLIGHT_SKBS) 256은 도움 안 됨**: CPU-bound라 stall이 skb-window 아님(스톡땐 +15%였으나 page_pool 후 무효). 확인 후 64로 복구.
- **결론**: single-flow는 MTU4096(RX=HW 강제)에서 ~one-core-pps 한계(이론상 ~30-33G@100%)에 근접(현 26G/793Kpps). addressable lever는 copy 6%(zero-copy)뿐. 그 이상은 MTU8192(soft RX 필요) 또는 multi-flow.

### ★ zero-copy frag TX — 구현 plan (코드 다 읽음, fresh 실행용)
목표: payload를 MR 페이지 frag로(copy 제거). **page_pool과 달리 패킷 구성 변경→HW RX ICRC 엄격검증 통과 필요→multi-iter**.
1. `rxe_init_packet`(rxe_net.c): zero-copy시 `skb_put`을 paylen→**IB헤더길이(rxe_opcode[opcode].length)만** 선형. (헤더길이 인자 전달 필요.)
2. `finish_packet`(rxe_req.c): `copy_data` 대신 `rxe_add_payload_frags()` — copy_data의 SGE순회 미러링하되 `lookup_mr`+`rxe_mr_iova_to_index`+`xa_load(mr->page_list)`로 페이지 얻어 `skb_fill_page_desc`+`get_page`+dma cursor 전진+`skb->len/data_len` 갱신. 이어 `[pad+ICRC]` trailer frag.
3. `rxe_icrc_generate`(rxe_icrc.c): 선형헤더(rxe_icrc_hdr 그대로)+payload frag(`kmap_local_page`마다 rxe_crc32)+pad CRC, ICRC(~crc)를 **trailer frag**에 기록(payload_addr 아님).
4. per-QP trailer 페이지: rxe_qp_init_req서 alloc(8B슬롯 ring), cleanup서 free.
5. MR페이지 lifetime: frag마다 get_page→skb free시 자동 put. MR은 WQE완료(=TX후)까지 pinned라 안전.
- **디버깅 팁**: HW RX는 ICRC틀리면 조용히 drop→debug 느림. **먼저 soft TX→soft RX로** 테스트(수신측 `rxe_icrc_check` -EINVAL/카운터로 가시화), 정확해지면 HW RX로. 예상 이득 +6-8%(천장 근처).
- (선택) MTU 10240(enum7, OPA_MTU_10240): netdev MTU>10320 필요(NIC jumbo 한계 확인).
- 패치 모듈 재로드: `sudo rmmod mlx5_ib; sudo rmmod rdma_rxe; sudo insmod /usr/src/linux-6.6.9/drivers/infiniband/sw/rxe/rdma_rxe.ko; sudo rdma link add rxe0 type rxe netdev ens81f0np0` (양쪽). 복구: stock는 `modprobe rdma_rxe`.

### ★★ zero-copy frag TX — 구현 완료 & 측정 (correct, but REGRESSION)
§16 5단계 plan 그대로 구현. 송신측(sslab3) rxe만 패치. **runtime toggle** `module_param zcopy`(0644, `/sys/module/rdma_rxe/parameters/zcopy`)로 동일 바이너리 A/B.

**구현 (6파일, page_pool 위에 적층)**
- `rxe_param.h`: RXE_ZCOPY_MIN=512, RXE_TRAILER_SLOTS=512, RXE_TRAILER_SLOT_SZ=8.
- `rxe_verbs.h`/`rxe_qp.c`: per-QP `trailer_pg`(alloc_page 1장=512×8B 슬롯 ring) + `trailer_cursor`. init서 alloc, cleanup서 put_page.
- `rxe_net.c` `rxe_init_packet`: 인자 paylen→`linear_len`. zcopy시 IB헤더길이(`rxe_opcode[].length`)만 skb_put → 헤더<256라 page_pool 게이트 자연 우회→작은 alloc_skb. pkt->paylen은 full 유지.
- `rxe_mr.c` `rxe_add_payload_frags()`: copy_data의 SGE walk 미러. iova→index/page_offset→`xa_load(page_list)`→`skb_fill_page_desc`+`get_page`, skb->len/data_len/truesize 갱신, dma 커서 전진. DMA-MR이면 -EOPNOTSUPP.
- `rxe_req.c`: `rxe_qp_can_zcopy()`(SEND/WRITE non-inline, payload≥512, **num_sge==1 단일 xarray-MR**만 — 中도 fallback 불가하므로 strict 사전판정). `rxe_add_icrc_trailer()`(ring 슬롯서 [pad|ICRC] frag, ICRC는 placeholder). `finish_packet` zcopy 분기: frag+trailer 먼저→그 다음 `rxe_prepare`(udph/iph len이 frag 포함 봐야).
- `rxe_icrc.c` `rxe_icrc_generate`: `skb->data_len`로 zcopy 판별. frag 버전 = 선형헤더(rxe_icrc_hdr) + payload frag마다 kmap_local+rxe_crc32 + trailer의 pad → `~icrc`를 trailer 슬롯에 기록. 빌드 무경고.

**correctness (★ 완전 검증)** — 자작 `rcverify.c`(RC SEND, 비균일 패턴, 수신측 memcmp). 헤더는 noble libibverbs-dev .deb에서 추출, sslab3 `-l:libibverbs.so.1` 링크.
- soft↔soft (patched TX→stock RX): 512~4MB 전 사이즈 **byte-exact OK**. 4MB=~1024패킷 → 512슬롯 ring **wrap & 재사용**에도 무손상(slot clobber 없음 확인).
- **soft TX→HW RX**(CX5 silicon ICRC): 전 사이즈 **byte-exact OK**. HW가 ICRC 실리콘 검증→통과 = wire bytes+ICRC 완전 정확.
- bpftrace: `rxe_add_payload_frags` 1356회 vs `copy_data` 1회 = zcopy 경로 실제 동작 확인. dmesg 무경고/무패닉.

**측정 (interleaved A/B, soft TX→HW RX, MTU4096, sysfs 토글)**
| 시나리오 | zcopy OFF(=page_pool) | zcopy ON | Δ |
|---|---|---|---|
| single SEND -s64K | **24.8 G** | 19.4 G | **−21.5%** |
| single WRITE -s64K | 22.6 G | 19.8 G | −12.2% |
| 4-flow SEND | 20.2 G | 19.6 G | −2.7%(noisy) |

- **§16 예상(+6-8%) 반증.** zcopy는 **느려짐**. correct하지만 lever 아님.
- perf(interleaved라 신뢰): OFF는 memcpy ~4%(copy_data)+`mlx5e_consume_skb` 보유. ON은 그 memcpy 제거(✓)했으나 **분산된 추가비용으로 초과 상쇄** — (1)scatter skb의 `mlx5e_xmit` SG-DMA 매핑, (2)ICRC가 hot 선형버퍼 대신 **cold user page를 kmap_local로 재독**(copy 안 해도 어차피 1패스 읽음), (3)frag별 get/put_page atomic, (4)trailer memset+slot, (5)spinlock 증가.
- 구조적 해석: requester 1코어 sys-bound(78%)에서 copy는 §16서 이미 **6%뿐**. 그 6% 떼고 frag 기계장치(SG-DMA/kmap/refcount)를 더 얹으니 음수. **소프트 RXE single-flow는 copy-bound가 아니라 per-packet-overhead-bound** → copy 제거는 잘못된 lever.
- ⚠️ 측정중 sslab3 background `raid6_pq` md-resync 노이즈(perf 10%)— 단 interleaved 6라운드라 상대비교는 robust(전 라운드 일관 ON<OFF).

**상태/산출물**
- 패치 `.ko`(page_pool+MTU8192+**zcopy param**, srcver A6297CE): sslab3 `/usr/src/.../rdma_rxe.ko`(=`.zcopy` 백업). 소스 백업 `.zcbak`(zcopy 직전=page_pool baseline).
- 현재: sslab3 soft TX(patched, zcopy=Y, mlx5_ib 미적재), sslab4 HW RX(rocep23s0f0 ACTIVE). 헬퍼: `~/lab/rxe_work/`(소스+rcverify.c+ab_hwrx.sh), sslab 양쪽 `/tmp/rcverify`,`/tmp/ibvinc`.
- 복구: sslab3 `modprobe mlx5_ib`(HW복구)+`modprobe rdma_rxe`(stock). baseline 동작은 reload없이 `echo 0 > .../parameters/zcopy`.

### 결론
zero-copy frag TX = **구현·검증 완료(soft+HW correct), 그러나 throughput lever 아님(−12~21% single)**. §16의 "남은 copy 6%" 가설은 frag overhead가 그 이상이라 무효. soft RXE single-flow 천장은 copy가 아니라 per-packet PPS(이미 §16 결론과 합치). 다음 lever는 copy가 아니라 **packet 수 자체 줄이기**(MTU↑ soft↔soft, 또는 multi-flow).

---

## 17. 오늘 종합 요약 + 최종 상태 (정확 — §9는 초반 스냅샷이라 무시)

### 오늘의 핵심 성과 (한눈에)
| 항목 | 결과 |
|---|---|
| HW RoCE single QP | **98 G** (라인레이트, MTU≥1024 무관; MTU256만 75G=37Mpps HW천장) |
| SoftRoCE single (soft↔soft) | ~15 G (MTU4096) / **22 G (MTU8192 패치)** |
| **soft TX → HW RX single** | stock ~20G → **page_pool ~26G (+30%)** = TCP single(38G)의 68% |
| SoftRoCE multi-flow peak | IRQ분산 전 15G → **분산 후 50G(@4096) / 75G(@8192)** = TCP 4-stream(90.8G)의 82% |
| TCP (참조) | single 38.3G / 4-stream 90.8G |
| 지연 | HW 1.16us(p99.9 2us) / Soft 13us(p99.9 84us) / 비대칭 soft→HW 6us |

### 검증된 lever (SoftRoCE 가속)
1. **수신 IRQ 멀티코어 분산** — multi-flow 천장의 진짜 키 (단일코어 핀이 15G로 throttle). sslab4 systemd 영구 적용.
2. **MTU 8192** (rxe 패치, 비표준) — single+36%/multi+92%. RX도 8192 가능해야(soft↔soft) 유효; RX=HW면 4096 dormant.
3. **page_pool TX 버퍼 재활용** (rxe 패치) — soft TX single +30%. per-packet 8KB alloc/free(34%) 제거.
4. (배제) skb-window·workqueue플래그·lock·recv소켓·ICRC·단일TX큐 — 전부 red herring.

### 구조적 진실
- SoftRoCE 느림 = **per-packet을 커널 CPU가 처리**(HW는 ASIC 37Mpps, SW는 단일코어 ~0.5Mpps, 73배차). single-flow는 ~one-core-pps 한계.
- TCP 갭의 본질 = **MTU(4096 vs 9000)**, per-packet 효율 아님(둘 다 single-flow ~505Kpps).
- **HW RX가 soft TX를 +40% & 안정화**(latency-bound라 빠른 HW ACK가 stall↓). 반대(HW TX→soft RX)는 go-back-N 재전송 붕괴(0.84G).
- GPUDirect = **양 서버 GPU 없음 → 불가**(ASPEED 온보드만).

### 최종 서버 상태 (실제)
- **양쪽 공통**: kernel **6.6.9**, MTU **9000**(수동; netplan 미설정이라 부팅마다 재적용 필요 — 양쪽), HW RoCE `rocep23s0f0` ACTIVE, **stock rxe 로드**(srcver B79F3EE), 잔여 프로세스 0.
- **sslab4(수신)**: 커널 udpbatch→6.6.9 전환(GRUB 기본=6.6.9 영구). `spread-rxe-irqs.service`(enabled, NIC IRQ 24코어 분산 영구).
- **sslab3(송신)**: 빌드트리 `/usr/src/linux-6.6.9`. **패치 .ko = `/usr/src/.../rdma_rxe.ko` (page_pool + MTU8192 결합, win64)** — 재로드시 `rmmod mlx5_ib; rmmod rdma_rxe; insmod 그.ko; rdma link add rxe0 type rxe netdev ens81f0np0`. 백업 `.ppbak`/`.mtu8192bak`. helper `/tmp/rxe_reload.sh`(윈도우), `/tmp/rxe_wq_reload.sh`(wq플래그).
- ⚠️ stock으로 돌리려면 `modprobe rdma_rxe`. MTU 부팅 후 항상 확인.

### 미완 / 다음
- **zero-copy frag TX** — §16에 5단계 구현 plan 확정(코드 분석 완료, fresh 세션 실행 권장). 예상 +6-8%(천장 근처).
- event-driven 벤치(perftest busy-poll 제거)로 multi-flow 진짜 천장.
- MTU8192 + page_pool stack(soft↔soft 조건).
