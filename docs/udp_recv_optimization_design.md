# UDP recv 최적화 설계 — "단일코어에서 UDP를 TCP급으로"

작성: 2026-06-10 / 환경: CX5 mlx5, MTU9000, kernel 6.6.9, 진짜 단일코어(IRQ+consumer core1)
기반 측정: 260609 DailyNote, single-flow matrix memory

## 0. 문제 정의 (측정으로 확정)
진짜 단일코어(IRQ+consumer 모두 core1, governor performance, GSO+GRO on)에서:
- **TCP 43G (core 100%) vs UDP 28G (core 100%)** → UDP RX가 **per-byte ~1.54x 무거움** (둘 다 CPU-bound, overrun 아님).
- 2코어(NAPI=c1 / consumer=c3, 둘 다 consumer-bound 100%): **TCP 60G vs UDP 38G** → 1.58x.
- ⇒ 갭은 flow-control이 아니라 **RX 처리 비용 자체**. 정보이론 한계가 아니라 **리눅스 UDP recv 구현이 TCP보다 덜 최적화**된 implementation gap → 고치면 근접 가능.

## 1. 비용 분해 (perf -C, 함수 레벨)

### consumer 코어 (recvmsg+copy, 2코어서 binding 100%)
| func | UDP | TCP | 비고 |
|---|---|---|---|
| `copyout` | 58% | 68% | 실제 데이터 copy (지배적) |
| `__check_object_size` | 11% | 11% | HARDENED_USERCOPY, **frag당 1회** |
| `__skb_datagram_iter` | 5% | 4.7% | frag walk |
| `napi_pp_put_page`+`free_pcppages_bulk`+`skb_release_data` | **~5%** | ~1% | **UDP가 per-datagram skb/page free 더 함** |
| `put_cmsg`/`udp_recvmsg` | ~0.8% | (tcp ~2%) | gso_size cmsg |

→ 같은 copyout%인데 TCP가 1.5x 바이트/CPU = **TCP copy가 더 큰 contiguous 청크**. UDP는 per-datagram 구조로 **frag이 더 잘게 쪼개짐 + skb/page free churn**.

### NAPI 코어 (GRO build)
| func | UDP | TCP |
|---|---|---|
| `__napi_alloc_skb` | **17%** | 9% | **wire datagram당 skb 1개 alloc** |
| `mlx5e_add_skb_shared_info_frag` / `skb_from_cqe_nonlinear` | ~15% | ~18% | mlx5 skb build |
| `napi_pp_put_page` | (consumer쪽) | 11% | page 반환 |
| `skb_gro_receive`/`udp_gro_receive`/`dev_gro_receive` | ~6% | ~2% | GRO 병합 |

→ UDP NAPI는 **datagram당 skb alloc(17%)** 이 무겁다. (단 2코어선 NAPI가 14~37%로 binding 아님; 단일코어선 consumer와 합산돼 천장 끌어내림.)

## 2. 코드 지점 (정확한 위치)

1. **copy walk — frag당 overhead**: `net/core/datagram.c __skb_datagram_iter()` 줄 24-48: `for (i=0; i<nr_frags; i++) { kmap; simple_copy_to_iter; }` — **frag마다 copy call + `check_object_size`**. frag 수가 많을수록(=잘게 쪼개질수록) 느림.
2. **HARDENED_USERCOPY**: `include/linux/thread_info.h:251 check_object_size()` ← `check_copy_size` ← `copy_to_iter`. frag/copy-call마다 호출 → ~11%.
3. **UDP GRO 병합 방식**: `net/ipv4/udp_offload.c:490-563 udp_gro_receive_segment()`.
   - 줄 560 `is_flist = !GRO_ENABLED(sk)`: **UDP_GRO on이면 is_flist=0 → 줄530 `skb_gro_receive`(paged frags, TCP식)**. (off면 frag_list — 더 나쁨.) ⇒ 우리 구성은 이미 paged지만, frag packing이 TCP보다 성김.
   - 줄 535 `UDP_GRO_CNT_MAX=64` & 64KB 캡 → super-skb ~7 datagram.
4. **per-datagram skb alloc/free**: NAPI `__napi_alloc_skb`(datagram당) + consumer `skb_release_data`/`napi_pp_put_page`/`free_pcppages_bulk`(super-skb 해제시 멤버 frag/page 다수 free).
5. **recvmsg**: `net/ipv4/udp.c:2011 udp_recvmsg()` → `skb_copy_datagram_msg` → 위 (1). super-skb당 1 recvmsg+1 free (이미 amortized).

## 3. 최적화 설계 (tier별, ROI 순)

### Tier 0 — 설정/일반 (즉시, 양 프로토콜 공통이나 UDP 비중↑)
- **`CONFIG_HARDENED_USERCOPY=n`** (또는 socket copy fast-path): `check_object_size` ~11% 제거. frag 많은 UDP가 더 이득.
- 검증: 빌드 후 단일코어 UDP/TCP 재측정. 예상 +10% 내외 양쪽.

### Tier 1 — per-datagram 비용 축소 (UDP→TCP 갭 닫기, ~1.5x→~1x 목표)
- **(1a) frag packing 개선**: UDP GRO 병합시 인접 frag을 page 단위로 합쳐 super-skb의 frag 수↓ → `__skb_datagram_iter`의 copy-call/`check_object_size` 횟수↓. 손댈 곳: `skb_gro_receive`(frags[] append 로직) / mlx5 RX가 datagram payload를 더 적은 frag으로 싣게.
- **(1b) skb head 재활용**: GRO 멤버 skb의 head를 즉시 page_pool로 recycle → NAPI `__napi_alloc_skb`(17%) + consumer free churn↓. (`napi_build_skb`+`skb_mark_for_recycle` 경로 확대.)
- **(1c) super-skb 키우기**: 64KB 캡 상향(IPv6 jumbogram / `gso_max_size`)으로 recvmsg/dequeue/free amortization↑. (IPv4는 64KB 고정 — 260605 BIG UDP 한계 참고 → IPv6 경로.)
- 목표: 단일코어 UDP 28→~40G, 2코어 38→~55G (TCP급).

### Tier 2 — copy 자체 제거 (천장 돌파, TCP 초월)
> 측정 근거: no-copy(MSG_TRUNC) = 단일코어 25G / **2코어 81G**. copyout(58-68%)이 지배적 비용이므로 이걸 없애는 게 최대 레버.
- **(2a) io_uring zero-copy RX** (`IORING_OP_RECV` + provided buffers / zc): copyout 제거, 페이지를 유저에 직접 매핑. app 재작성 필요(io_uring ring).
- **(2b) AF_XDP zerocopy**: NIC→유저 umem 직결. UDP/RoCE-bypass. 가장 큼(라인레이트 가능)하나 커널 stack 우회(GRO/socket 의미론 포기).
- **(2c) devmem TCP식 page-flipping recv를 UDP로**: skb 페이지를 유저 VMA로 flip(copy 0). 큰 변경.
- 목표: 2코어 UDP 80G+(TCP 60G 초월), 단일코어는 NAPI 한계 ~25G(copy 없어도 NAPI가 한 코어 포화).

## 4. 권장 진행 순서 (설계→구현→검증)
1. **Tier 0** 먼저(빌드 1회, 리스크 0): HARDENED_USERCOPY off로 양쪽 baseline 재측정 → 순수 copy/stack 비용 노출.
2. **Tier 1b(skb recycle)** + **1a(frag packing)**: UDP NAPI/free churn 공략. A/B로 UDP 단일코어 28G가 오르는지(목표 ~40G=TCP급) 확인. ★ 이게 "UDP를 TCP와 동일하게"의 핵심.
3. **Tier 2(zero-copy)**: 천장 자체를 올리려면. io_uring RECV_ZC 프로토타입(udp_sink 개조)로 2코어 81G 재현 → 실 app(iperf3) 적용.

## 5. 주의 / 반례
- **단일코어는 copy 없애도 NAPI가 ~25G서 포화** (no-copy 단일코어 25.5G). 즉 Tier2(zero-copy)는 **2코어 이상**에서만 천장 돌파. 단일코어 천장(~40-43G=TCP)은 Tier0+1(copy 효율화)로 도달이 목표.
- frag packing/병합은 **copy 효율 vs 병합 CPU** 트레이드오프 — 병합이 과하면 NAPI가 무거워짐. A/B 필수.
- HARDENED_USERCOPY off는 보안 영향(연구 환경 한정).
- per-datagram 의미론(메시지 경계, gso_size)은 UDP 본질 — 완전 제거 불가하나 amortize는 가능.
