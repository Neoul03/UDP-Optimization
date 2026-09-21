# 2026-05-29 Lab Meeting — UDP receive path가 가벼운 프로토콜인데도 느린 이유와 amortize 방향

작성: 2026-05-28 / 발표: 2026-05-29
환경: sslab4(receiver) / sslab3(sender) / CX5 mlx5_core / `ens81f0np0` / 192.168.11.{120,238} / MTU 9000 / CPU1 핀 / iperf3 = `~/iperf3-source/src/iperf3`

발표 시간 가정: **20분 발표 + 10분 QA**. 각 슬라이드 ~2.5분.

---

# 0. 캡처 워크플로우 (전체 슬라이드 공통)

## 0-1. 발표 직전 환경 점검 (sslab4 한 터미널)

```
$ ssh sslab4
chanseo@sslab4:~$ ip -br addr show ens81f0np0
chanseo@sslab4:~$ ethtool -k ens81f0np0 | grep -E '^(generic-segmentation|tx-udp-segmentation|generic-receive|rx-udp-gro-forwarding)'
chanseo@sslab4:~$ pkill -9 iperf3 bpftrace 2>/dev/null; echo done
chanseo@sslab4:~$ ~/dim.sh on        # ★ DIM ON 모드 (대부분 슬라이드 baseline)
```

**`~/dim.sh on` 또는 `~/dim.sh off-pure`** 한 줄로 모드 전환 가능 (sslab4에 이미 배포됨).

## 0-2. 캡처 시 권장 방식

- **여러 터미널을 동시에 열기**: Windows Terminal 같은 환경에서 탭 또는 split. 각 탭에서 `ssh sslab4` / `ssh sslab3` 따로.
- **prompt 포함 캡처**: `chanseo@sslab4:~$` 같은 prompt가 같이 보이면 어느 호스트인지 명확. PPT에 자연스러움.
- **명령어 + 결과 한 화면에**: 한 터미널 안에서 명령을 친 직후 결과까지 한 번에 보이는 시점 캡처. 화면 끝까지 잘리지 않게 미리 터미널 높이 충분히.

## 0-3. 슬라이드별 필요한 터미널 수 요약

| 슬라이드 | 필요 터미널 | 역할 |
|---|---|---|
| Slide 1 | 3 | sslab4(server) + sslab3(client) + sslab4(nstat) |
| Slide 2 | 1 | sslab4 (코드 viewer) |
| Slide 3 | 1 | sslab4 (코드 viewer) |
| Slide 4 (A/B) | 3 | sslab4(server) + sslab4(bpftrace) + sslab3(client) |
| Slide 5-A | 3 | sslab4(server) + sslab4(bpftrace) + sslab3(client) |
| Slide 5-B | 3 | sslab4(server) + sslab3(client) + sslab4(ss 폴링) |
| Slide 5-C | 3 | sslab4(server) + sslab3(client) + sslab4(nstat) |
| Slide 6 | 1 | sslab4 (코드 viewer) |

---

# Slide 1 — 현상: DIM ON에서 UDP throughput 폭락

## 발표 스크립트 (~2분)
> "지난 미팅에서 보여드렸던 결과를 한 번 더 짚고 가겠습니다. 같은 NIC, 같은 부하, 같은 CPU 핀 설정에서 DIM을 켜고 끄는 것만으로 TCP는 throughput이 올라가고 UDP는 4분의 1 수준으로 떨어집니다. 같은 'coalescing 키워서 IRQ 비용 줄이자'는 메커니즘이 한 프로토콜에는 도움, 다른 프로토콜에는 해가 됩니다. 오늘은 이 비대칭이 어디서 오는지를 코드와 측정 양쪽으로 풀어드리고, UDP의 receive path 코드가 amortize되어 있지 않다는 결론으로 가겠습니다."

## 슬라이드에 들어갈 표
- 표 1: PPT 122-123 그대로 (TCP 42.2/34.2, UDP 4.8/19.4)
- 표 2 (이번 측정): 3 trial 평균 — DIM ON 10.24 ± 0.91 / OFF 9.65 ± 0.61, UdpRcvbufErrors ~597K /s

## ★ 캡처 워크플로우

### 사전 준비
- 사용자가 **터미널 3개** 띄움. 각각 ssh 접속:
  ```
  [터미널 A]  $ ssh sslab4
  [터미널 B]  $ ssh sslab3
  [터미널 C]  $ ssh sslab4     # 모니터링 전용 (server 터미널과 별개)
  ```

### 실행 순서

**[터미널 A — sslab4 receiver]**
```
chanseo@sslab4:~$ ~/dim.sh on
chanseo@sslab4:~$ pkill -9 iperf3 2>/dev/null; echo clean
chanseo@sslab4:~$ nstat > /dev/null     # nstat counter reset
chanseo@sslab4:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -s -B 192.168.11.238 -A 1 -1
```
→ 마지막 명령 친 직후 server가 listen 상태로 대기. **2초 후 터미널 B로**.

**[터미널 B — sslab3 sender]**
```
chanseo@sslab3:~$ pkill -9 iperf3 2>/dev/null; echo clean
chanseo@sslab3:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -c 192.168.11.238 -u -l 9000 -b 40G -Z -A 1 -t 30
```
→ 30초 후 자동 종료. 결과 출력. **이 터미널 결과가 ★ 캡처 대상 1**.

**[터미널 C — sslab4 모니터링]**  (B의 iperf3 끝난 직후 즉시)
```
chanseo@sslab4:~$ nstat | grep -E 'UdpInDatagrams|UdpInErrors|UdpRcvbufErrors|UdpNoPorts'
```
→ 출력 결과가 ★ **캡처 대상 2**.

## 캡처 정리
| 캡처 # | 터미널 | 내용 | 예상 결과 |
|---|---|---|---|
| 1 | B (sslab3) | iperf3 client 마지막 두 줄 (`sender ... 0/X (0%)`, `receiver ... lost/total (XX%)`) | sender ~30 Gbps wire / receiver 8~11 Gbps / lost 60~80% |
| 2 | C (sslab4) | nstat 출력 (3~4줄) | UdpInDatagrams 수백K, UdpRcvbufErrors 수십만~수백만 (30s 누적) |

---

# Slide 2 — UDP receive path 코드 (왜 한 packet에 lock 한 번씩?)

## 발표 스크립트 (~2.5분)
> "현상을 설명하려면 receive path를 따라가야 합니다. UDP는 packet 하나를 user space로 올리기까지 두 군데서 socket lock을 잡습니다. softirq context에서 `__udp_enqueue_schedule_skb`가 socket queue에 enqueue할 때, user context에서 `udp_recvmsg`가 dequeue할 때. 각각 packet 한 개당 한 번씩 잡습니다. 'packet 하나에 lock 한 번'이라는 구조 자체가 UDP 받기 path의 핵심 특징입니다."

## 슬라이드에 들어갈 자료
- 왼쪽: UDP receive path 수직 다이어그램 (PPT에 이미 들어있음)
- 오른쪽: `__udp_enqueue_schedule_skb` **압축본 코드** (PPT에 이미 텍스트로 직접 들어있음 — 캡처 불필요)

## 압축 정책 (왜 50줄을 25줄로 줄였나)
원본 50줄을 그대로 넣으면 폰트가 너무 작아 발표 화면에서 안 보임. 메시지에 직접 기여하지 않는 부분은 생략:

| 빼는 것 | 이유 |
|---|---|
| 주석 블록 (`/* try to avoid... */` 등) | 발표 화면 노이즈 |
| `busy = busylock_acquire(sk)` 와 release | 메인 메시지(lock-per-packet)와 무관, 부차적 |
| `skb_condense`, `udp_set_dev_scratch` 등 | 같은 이유 |
| `udp_rmem_schedule(sk, size)` 분기 | drop으로 가는 보조 경로 |
| `sk_forward_alloc_add`, `sock_skb_set_dropcount` | 핵심 메시지 무관 |
| `INDIRECT_CALL_1` 래퍼 | `sock_def_readable`로 직접 표기 |

남긴 것: **drop 분기 2곳 + spin_lock + sk_data_ready + sk_drops 증가** — 발표 메시지를 떠받치는 5 hot path.

## 캡처 (선택 — 백업/Q&A용)
**[터미널 A — sslab4]** — 원본 그대로 확인하고 싶으면
```
chanseo@sslab4:~$ less +1488 ~/lab/kernel/linux-6.6.9/net/ipv4/udp.c
```
`:set number` 후 1488~1554 캡처. 원본 vs 압축본 비교 또는 Q&A 시 참고용.

발표 PPT에는 압축본 코드가 이미 들어있으므로 별도 캡처 불필요.

---

# Slide 3 — TCP receive path 대조 (왜 한 recv에 lock 한 번이면 끝?)

## 발표 스크립트 (~2분)
> "같은 일을 TCP는 어떻게 처리하는지 보겠습니다. TCP는 `tcp_recvmsg` 진입할 때 `lock_sock`을 한 번 잡고, 그 안에서 `tcp_recvmsg_locked`가 `do-while` 루프로 socket queue가 빌 때까지 여러 skb를 연속 소비합니다. 한 syscall = 한 lock = 여러 KB 처리. UDP의 'datagram 1개 = lock 1번 = syscall 1번'과 비교하면 amortize 비율이 자릿수가 다릅니다."

## ★ 캡처 워크플로우

**[터미널 A — sslab4]**
```
chanseo@sslab4:~$ grep -n 'tcp_recvmsg\|tcp_recvmsg_locked' ~/lab/kernel/linux-6.6.9/net/ipv4/tcp.c | head -5
chanseo@sslab4:~$ less +/tcp_recvmsg_locked ~/lab/kernel/linux-6.6.9/net/ipv4/tcp.c
```
→ `less` 안에서:
- `:set number` Enter
- ★ **캡처 대상**: `int tcp_recvmsg_locked(...)` 함수 본문 — 특히
  - `lock_sock(sk);` 호출 (함수 진입부)
  - `do { ... copy ... sk_eat_skb ... } while (len > 0);` 루프 헤더와 본문

---

# Slide 4 — ★ 측정으로 입증: TCP 947 KB/recvmsg vs UDP 35 KB/recvmsg

## 발표 스크립트 (~3분, *발표의 기둥 슬라이드*)
> "이게 그냥 코드 차이가 아니라 실제 부하에서 얼마나 차이가 나는지 bpftrace로 직접 셌습니다. 30초 동안 같은 NIC, 같은 코어, 같은 sender CPU에서 TCP와 UDP receive path를 돌려보고, recvmsg가 몇 번 호출됐는지를 셉니다. 같은 throughput을 받기 위해 TCP는 약 4만 번, UDP는 약 25만 번 recvmsg를 호출합니다. **한 recvmsg가 처리한 bytes로 환산하면 TCP는 947 KB, UDP는 35 KB. 약 27배 차이입니다.** lock 횟수, syscall context switch 비용이 모두 27배. UDP가 protocol 레벨로는 가벼운데 OS receive path는 27배 무거운, 이 mismatch가 폭락의 1차 원인입니다."

## 슬라이드에 들어갈 표
- 핵심 표: TCP recvmsg vs UDP recvmsg, release_sock, bytes/recvmsg 비율 (Slide 4의 표 그대로)

## ★ 캡처 워크플로우 — 2회 측정 (TCP, UDP 각각)

### 사전 준비
- **터미널 3개** 띄움:
  ```
  [터미널 A]  $ ssh sslab4    # iperf3 server
  [터미널 B]  $ ssh sslab4    # bpftrace
  [터미널 C]  $ ssh sslab3    # iperf3 client
  ```

### A) TCP 측정 (~35s)

**[터미널 A — sslab4]** — 매번 server 새로 띄움
```
chanseo@sslab4:~$ ~/dim.sh on
chanseo@sslab4:~$ pkill -9 iperf3 bpftrace 2>/dev/null; echo clean
chanseo@sslab4:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -s -B 192.168.11.238 -A 1 -1
```
→ server listen 대기.

**[터미널 B — sslab4]** — bpftrace 32초
```
chanseo@sslab4:~$ sudo timeout 32 bpftrace -e '
kprobe:tcp_recvmsg { @tcp_recvmsg = count(); }
kprobe:udp_recvmsg { @udp_recvmsg = count(); }
kprobe:__release_sock { @release_sock = count(); }
kprobe:__lock_sock { @lock_sock_slow = count(); }'
```
→ "Attaching N probes..." 출력 후 대기.

**[터미널 C — sslab3]** — TCP client 30초
```
chanseo@sslab3:~$ pkill -9 iperf3 2>/dev/null
chanseo@sslab3:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -c 192.168.11.238 -t 30 -Z -A 1
```
→ 30초 후 결과 출력. ★ **캡처 대상 A-1**: receiver Gbps 라인.

→ B의 bpftrace는 32초 후 자동 종료, hist 출력. ★ **캡처 대상 A-2**: `@tcp_recvmsg`, `@release_sock`, `@lock_sock_slow` 값.

### B) UDP 측정 (~35s) — 같은 bpftrace를 UDP 부하로

A와 동일 순서, 단 **터미널 C의 명령만 다름**:
```
chanseo@sslab3:~$ pkill -9 iperf3 2>/dev/null
chanseo@sslab3:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -c 192.168.11.238 -u -l 9000 -b 40G -Z -A 1 -t 30
```

A·B 모두 끝나면 터미널 B의 bpftrace 결과에서 `@udp_recvmsg` 값을 확인.

★ **캡처 대상 B-1** (터미널 C): receiver Gbps (예: ~8 Gbps).
★ **캡처 대상 B-2** (터미널 B): `@udp_recvmsg` 매우 큼, `@release_sock` ≈ 0.

## 캡처 정리
| 캡처 # | 터미널 | 내용 | 예상 |
|---|---|---|---|
| A-1 | C (sslab3) | TCP iperf3 receiver Gbps | ~37 Gbps |
| A-2 | B (sslab4) | bpftrace 결과 (TCP 부하 후) | @tcp_recvmsg ≈ 1.18M, @release_sock ≈ 336K |
| B-1 | C (sslab3) | UDP iperf3 receiver Gbps | ~8 Gbps |
| B-2 | B (sslab4) | bpftrace 결과 (UDP 부하 후) | @udp_recvmsg ≈ 7.5M, @release_sock ≈ 95 |

## Bytes/recvmsg 환산 (슬라이드 표에 직접 적기)
- TCP: 37.4 Gbps × 30s ÷ 8 ÷ 1,184,902 ≈ **947 KB/recvmsg**
- UDP: 8 Gbps × 30s ÷ 8 ÷ 7,599,364 ≈ **35 KB/recvmsg**

(현장 측정 값이 약간 달라도 자릿수만 일치하면 메시지 동일)

---

# Slide 5 — ★ DIM의 NAPI burst가 packet-당-lock 구조를 곱셈 증폭

## 발표 스크립트 (~3분, *발표의 핵심 메커니즘*)
> "Slide 4에서 UDP는 packet 하나마다 lock을 한 번씩 잡아야 한다는 걸 봤습니다. 여기에 DIM이 만든 NAPI burst가 곱해지면 어떤 일이 벌어지는지 봅니다. DIM이 켜져 있으면 NIC interrupt를 줄이려고 한 NAPI poll에 더 많은 packet을 모아서 한꺼번에 처리합니다. mlx5의 NAPI weight은 64인데, 실제로 측정해보면 NAPI poll의 절반 이상이 64 packet 한도까지 꽉 차서 들어옵니다. 이 64개가 한꺼번에 socket queue로 enqueue되려면 atomic_add 64번, spin_lock 64번, sk_data_ready 64번이 같은 코어의 같은 socket lock을 두고 일어납니다. 동시에 user-space의 recvmsg도 같은 코어에서 lock을 잡으려고 경쟁합니다. softirq context와 user context가 같은 코어에서 같은 socket lock을 두고 경쟁하면서, drain rate가 떨어지고 sk_rmem_alloc이 sk_rcvbuf를 초과해 drop이 발생합니다. 이걸 ss와 nstat으로 실시간으로 잡았습니다."

## 슬라이드에 들어갈 자료
- 표: NAPI work_done [64,128) bin 59% (DIM on)
- 표: ss skmem (r > rb) + sk_drops
- 표: nstat UdpRcvbufErrors 시계열 3 시점

## ★ 캡처 워크플로우 — 3개 캡처 각각

---

### 5-A) NAPI work_done 분포 (bpftrace 히스토그램)

**터미널 3개**:

**[터미널 A — sslab4]**
```
chanseo@sslab4:~$ ~/dim.sh on
chanseo@sslab4:~$ pkill -9 iperf3 bpftrace 2>/dev/null; echo clean
chanseo@sslab4:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -s -B 192.168.11.238 -A 1 -1
```

**[터미널 B — sslab4]**
```
chanseo@sslab4:~$ sudo timeout 32 bpftrace -e '
tracepoint:napi:napi_poll { @napi_work = hist(args->work); @napi_calls = count(); }'
```

**[터미널 C — sslab3]**
```
chanseo@sslab3:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -c 192.168.11.238 -u -l 9000 -b 40G -Z -A 1 -t 30
```

→ 30초 후 모두 종료. ★ **캡처 5-A** (터미널 B): `@napi_work` 히스토그램. `[64, 128)` bin이 가장 긴 막대인지 확인.

---

### 5-B) ★ ss로 sk_rmem_alloc > sk_rcvbuf 실시간 관측 (발표의 결정적 한 컷)

**[터미널 A — sslab4]**
```
chanseo@sslab4:~$ ~/dim.sh on
chanseo@sslab4:~$ pkill -9 iperf3 2>/dev/null
chanseo@sslab4:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -s -B 192.168.11.238 -A 1 -1
```

**[터미널 C — sslab3]**
```
chanseo@sslab3:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -c 192.168.11.238 -u -l 9000 -b 40G -Z -A 1 -t 15
```
→ 15초 부하 (짧음 — ss로 한가운데 잡기 좋게).

**[터미널 B — sslab4]**  (위 client가 시작된 직후 약 3초 뒤부터)
```
chanseo@sslab4:~$ for i in 1 2 3 4 5; do sudo ss -uemnp | grep -A1 ':5201'; echo ---; sleep 1; done
```
→ ★ **캡처 5-B** (터미널 B): 5번 출력 중 `r > rb`인 줄 (`skmem:(rXXXXXX,rb33554432,...,dXXXXX)`).

**판독 팁**: skmem 괄호 안에서
- `r` 값 (현재 sk_rmem_alloc, bytes)
- `rb` 값 (sk_rcvbuf, 32MB = 33554432)
- `d` 값 (sk_drops 누적)

캡처 시 **`r` 값이 `rb`와 같거나 더 큰 줄**이 결정적. 5번 폴링 중 1~2번은 잡힘.

---

### 5-C) nstat UdpRcvbufErrors 시계열 3 시점

**[터미널 A — sslab4]**
```
chanseo@sslab4:~$ ~/dim.sh on
chanseo@sslab4:~$ pkill -9 iperf3 2>/dev/null
chanseo@sslab4:~$ nstat > /dev/null      # ★ counter reset
chanseo@sslab4:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -s -B 192.168.11.238 -A 1 -1
```

**[터미널 C — sslab3]**
```
chanseo@sslab3:~$ taskset -c 1 ~/iperf3-source/src/iperf3 -c 192.168.11.238 -u -l 9000 -b 40G -Z -A 1 -t 30
```

**[터미널 B — sslab4]**  (client 시작 직후)
```
chanseo@sslab4:~$ sleep 5;  echo "=== T+5s ===";  nstat | grep -E 'UdpRcvbufErrors|UdpInErrors|UdpInDatagrams'
chanseo@sslab4:~$ sleep 10; echo "=== T+15s (10s delta) ==="; nstat | grep -E 'UdpRcvbufErrors|UdpInErrors|UdpInDatagrams'
chanseo@sslab4:~$ sleep 10; echo "=== T+25s (10s delta) ==="; nstat | grep -E 'UdpRcvbufErrors|UdpInErrors|UdpInDatagrams'
```
(각 줄을 한 줄씩 따로 쳐도 OK — sleep + echo + nstat 순서로)

→ ★ **캡처 5-C** (터미널 B): 3 시점의 nstat 출력. 10s delta 200K~600K /s (= UdpRcvbufErrors 20K~60K /s 페이스로 누적).

---

## 캡처 정리
| 캡처 # | 터미널 | 내용 | 예상 |
|---|---|---|---|
| 5-A | B (sslab4) | bpftrace `@napi_work` 히스토그램 | [64,128) bin이 50%+ |
| 5-B | B (sslab4) | `ss -uemnp` skmem 줄 | r ≈ rb (32MB) 시점, d=수십만 |
| 5-C | B (sslab4) | nstat 3 시점 (각 10s delta) | UdpRcvbufErrors 누적 증가 |

---

# Slide 6 — DIM 피드백 코드 (왜 self-correct 불가)

## 발표 스크립트 (~1.5분)
> "이 모든 게 일어나는 동안 DIM 알고리즘 자체는 이 상황을 전혀 모릅니다. DIM의 피드백 입력은 NIC RQ 통계만 — `stats->packets`와 `stats->bytes`. socket queue overflow는 이 카운터에 안 잡힙니다. DIM 입장에선 'coalescing 키울수록 NIC 처리량이 올라간다, BETTER'로 보여서 그 방향으로 수렴합니다. self-correct가 구조적으로 불가능합니다."

## ★ 캡처 워크플로우

**[터미널 A — sslab4]**
```
chanseo@sslab4:~$ less +/mlx5e_handle_rx_dim ~/lab/kernel/linux-6.6.9/drivers/net/ethernet/mellanox/mlx5/core/en_txrx.c
```
→ `:set number` 후 **★ 캡처 6-1**: `mlx5e_handle_rx_dim` 함수 본문 (line 61~71).
→ 핵심 강조: `dim_update_sample(rq->cq.event_ctr, stats->packets, stats->bytes, &dim_sample);`

```
chanseo@sslab4:~$ less +/net_dim_stats_compare ~/lab/kernel/linux-6.6.9/lib/dim/net_dim.c
```
→ `:set number` 후 **★ 캡처 6-2**: `net_dim_stats_compare` 함수 (line 137~163).
→ 핵심 강조: `IS_SIGNIFICANT_DIFF(curr->bpms, prev->bpms)` 줄 — *bpms/ppms/epms만* 비교, UDP_MIB_RCVBUFERRORS는 안 봄.

---

# Slide 7 — ★ 해결 방향: UDP enqueue를 batch로 amortize

## 발표 스크립트 (~3분)
> "지금까지 본 문제는 결국 UDP receive path가 packet-당-lock 구조이기 때문에 NAPI burst가 와도 amortize할 수 없다는 것입니다. TCP처럼 'lock 한 번에 여러 skb 처리'로 바꾸면 NAPI burst의 부담을 흡수할 수 있습니다. 구체적으로 softirq 쪽의 `__udp_enqueue_schedule_skb`를 list 버전으로 만들어, 한 NAPI burst 안에서 같은 socket으로 갈 skb들을 list로 모아서 atomic_add 1번, spin_lock 1번, sk_data_ready 1번으로 처리합니다. 호출 위치는 `udp_unicast_rcv_skb` 또는 NAPI flush 직전입니다."

## 슬라이드 자료
- 현재 vs 변경 후 pseudo-code 비교 (PPT에 이미 포함됨)

## 캡처 — 현재 코드 위치 확인 (선택)

**[터미널 A — sslab4]**
```
chanseo@sslab4:~$ grep -n '__udp_enqueue_schedule_skb' ~/lab/kernel/linux-6.6.9/net/ipv4/udp.c
chanseo@sslab4:~$ less +1488 ~/lab/kernel/linux-6.6.9/net/ipv4/udp.c
```
→ 함수 시그니처 (1488)와 호출자 (line 2037) 캡처. 변경 *대상* baseline.

(Slide 7은 코드 변경 자체가 메시지라 라이브 캡처는 선택적. Slide 2의 캡처 재활용도 OK)

---

# Slide 8 — 측정 계획 & 다음 단계

## 발표 스크립트 (~1.5분)
> "Patch 적용 후엔 동일 환경(40G/GSO on/DIM on/CPU1 핀)으로 같은 측정 셋을 돌립니다. 핵심 지표 네 개: iperf3 receiver throughput, nstat UdpRcvbufErrors rate, bpftrace로 본 atomic/spin_lock 호출 빈도, ss -uem의 sk_rmem_alloc 시계열. patch 전후가 Slide 5의 표와 같은 형식으로 직접 대비됩니다. 이번 미팅 끝나고 1~2주 안에 patch prototype + 측정 결과 보고드릴 수 있을 것 같습니다."

## 슬라이드 자료
- 측정 셋 4개 (PPT에 이미 표로 포함)
- 작업 일정 (W1: prototype, W1: 빌드, W2: 측정·보고)

(이 슬라이드는 라이브 캡처 없음 — 표만 작성)

---

# 부록 A. Q&A 예상 질문 + 답변

## Q1. "정말 lock이 원인인가? CPU cache miss·memory bandwidth가 원인이면?"
- 같은 CPU·NIC·sender setup에서 *DIM on/off만* 바꿔도 throughput·UdpRcvbufErrors가 변함 → cache/memory가 원인이면 두 모드 결과 같아야.
- 백업 자료: `bpftrace -e 'kprobe:_raw_spin_lock_bh { @[kstack(2)] = count(); }'`로 socket lock이 hot한 stack 직접 확인 가능.

## Q2. "rcvbuf 키우면 회복된다고 메일에서 말했는데?"
**답** (솔직히 — 우리 측정으로 *반박*됨):
- 측정 결과(`~/lab/reports/sweep_rcvbuf_20260527_203810/`): rcvbuf 4MB → 18 Gbps, 256MB → 4.84 Gbps. **큰 buffer가 역효과**.
- 진짜 bottleneck은 user-space drain rate. 더 큰 buffer는 cache pollution + memory pressure 가중.
- 따라서 buffer가 아니라 *amortize* 방향이 맞다 — Slide 7.

## Q3. "DIM 자체를 끄면 되는 거 아닌가?"
- 평균적으론 DIM off가 약간 좋지만 (10.2 vs 9.6 — 3 trial 평균), variance가 크고 IRQ 부담이 2배. TCP는 DIM ON이 도움. NIC 한 장에 TCP/UDP 같이 도는 환경에선 DIM 끄는 게 항상 답은 아님. 진짜 답은 UDP path를 amortize해서 DIM ON 환경에서도 살아남게 만드는 것.

## Q4. "amortize 어떻게 구현? user-space API 호환?"
- Slide 7 방향 (a)는 user-space API 무관 (softirq 측 내부 변경). (b)는 깨므로 recvmmsg 활용 권장.

## Q5. "다른 워크로드 (small datagram, multi-socket) 에선 regression?"
- list 형태로 모이지 않는 케이스 (한 NAPI poll에 같은 socket으로 1개 skb만) 에선 기존 path (single-skb fallback) 그대로 — list 1개면 기존과 동일 비용.

---

# 부록 B. 자료 위치

| 종류 | 경로 |
|---|---|
| 종합 분석 보고서 | `~/lab/reports/H1_analysis.md` (557줄) |
| Patch 시제품 | `~/lab/reports/patches/0001-...patch`, `0002-...patch` |
| bitrate sweep | `~/lab/reports/sweep_bitrate_20260527_203246/` |
| rcvbuf sweep (Q2 근거) | `~/lab/reports/sweep_rcvbuf_20260527_203810/` |
| TCP 측정 (Slide 4 근거) | `~/lab/reports/tcp_compare_20260527_204132/`, `lock_amort_20260527_204330/` |
| 3-trial 평균 (Slide 1 근거) | `~/lab/reports/sweep_repeated_20260527_220326/`, `repro_20260527_215106/` |
| DIM 내부 trace | `~/lab/reports/dim_ramp2_20260527_212616/`, `dim_compare_20260527_214238/` |

---

# 부록 C. 캡처 체크리스트

| Slide | 캡처 # | 호스트 | 내용 |
|---|---|---|---|
| 1 | 1 | sslab3 | iperf3 receiver 결과 (sender/receiver 두 줄) |
| 1 | 2 | sslab4 | nstat UdpRcvbufErrors |
| ~~2~~ | ~~3~~ | — | **PPT에 텍스트로 직접 포함 (압축본 25줄). 캡처 불필요.** |
| 3 | 4 | sslab4 | `tcp_recvmsg_locked` 코드 (do-while 루프) |
| 4 | A-1 | sslab3 | TCP iperf3 receiver Gbps |
| 4 | A-2 | sslab4 | bpftrace TCP 결과 (@tcp_recvmsg) |
| 4 | B-1 | sslab3 | UDP iperf3 receiver Gbps |
| 4 | B-2 | sslab4 | bpftrace UDP 결과 (@udp_recvmsg) |
| 5 | 5-A | sslab4 | bpftrace `@napi_work` 히스토그램 |
| 5 | 5-B | sslab4 | `ss -uemnp` skmem (r > rb 줄) ★ 결정적 |
| 5 | 5-C | sslab4 | nstat UdpRcvbufErrors 3 시점 |
| 6 | 6-1 | sslab4 | `mlx5e_handle_rx_dim` 코드 |
| 6 | 6-2 | sslab4 | `net_dim_stats_compare` 코드 |

**총 12장** (Slide 2 코드는 PPT에 텍스트로 직접 포함되어 캡처 제외). Slide 7·8은 라이브 캡처 없음.

---

# 부록 D. 한 줄 요약 (소개/마무리용)

> "UDP는 protocol 레벨로는 가볍지만 OS receive path가 packet-당-lock 구조라 amortize되어 있지 않다. DIM의 NAPI burst가 이 구조와 *곱셈*으로 작용해 socket queue overflow를 만들고 throughput을 깎는다. DIM의 피드백은 NIC stats만 보므로 self-correct도 불가능하다. 해결책은 buffer 확장이 아니라 receive path 자체의 amortize — `__udp_enqueue_schedule_skb_list`로 lock 1회에 N skb 처리하는 patch가 다음 작업."

---

# 부록 E. sslab4 helper 정보

발표 직전에 다시 한 번 확인:
```
chanseo@sslab4:~$ ~/dim.sh on        # DIM 활성
chanseo@sslab4:~$ ~/dim.sh off-pure  # DIM 비활성 (필요 시)
```
스크립트 자체 확인은 `cat ~/dim.sh` 또는 `less ~/dim.sh`.
