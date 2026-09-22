# Patch triage against Linux 7.2.7 and 6.18.53 LTS

Audited 2026-09-22. Upstream sources: `linux-7.2.7` (current stable) and
`linux-6.18.53` (newest longterm). There is no 7.x LTS yet, so the port
target is **6.18.53** while the code audit is done against **7.2.7**.

## Verdict

| patch | verdict | reason |
|---|---|---|
| 0001 net_dim socket drop feedback | **drop** | DIM refuted experimentally as a factor in the collapse (4/10 good with it on, 4/10 with it off) |
| 0002 net_dim dynamic threshold | **drop** | same refutation |
| 0003 udp batch enqueue of GRO segments | **drop** | superseded upstream by the per-NUMA `udp_prod_queue` llist, present in both 6.18.53 and 7.2.7 |
| 0004 producer batch + `UDP_RECV_BATCH` | **drop** | helps only small, syscall-bound datagrams (~21%); moot once UDP_GRO is on, and 0003's half is superseded |
| 0005/0005b iperf3 GSO+GRO | **keep** | measurement tooling, not kernel; without it the workload cannot be generated or accounted at all |
| 0006 udp rcvbuf autotune | **keep, redesign** | the premise survives: 7.2.7 still reads a static `sk_rcvbuf`. But the growth mechanism measured worthless, the 32MB default cap is wrong, and it is per-socket where the resource is global |
| 0007 udp early drop (socket level) | **drop** | negative result — no gain over the existing full-queue drop |
| 0008 udp rx shed (driver level) | **keep, redesign** | real effect (+42% under flood at MTU 9000, +12% at MTU 1500) but protocol-blind, per-queue rather than per-socket, and mlx5-specific |

Eight interventions, six dead: two refuted by experiment, one superseded
upstream, one moot, one a negative result, one merely tooling. The two that
survive turn out to be two halves of the same control problem.

## What upstream already does (so we must not claim it)

`net/ipv4/udp.c:1655-1785` @ 7.2.7 — `__udp_enqueue_schedule_skb`:

- `busylock` is gone. Producers now append lock-free to a per-NUMA
  `udp_prod_queue` llist; the producer whose `llist_add()` returns true takes
  the drain role and moves the whole batch under one `spin_lock(&list->lock)`.
  This is the same amortisation our 0003 attempted, done better.
- `skb_condense()` still fires at `rmem > (rcvbuf >> 1)`, unchanged from 6.6.9.
  This is the code our bad-state measurements caught running 0.96 times per
  packet.
- Drop is still "queue full, drop here", accounted through `udp_drops_inc()`
  and `numa_drop_add()`. Nothing sheds earlier than the socket.

## What upstream still does not do

- **No receive-buffer autotuning for UDP.** `rcvbuf = READ_ONCE(sk->sk_rcvbuf)`
  is the whole of it, in 7.2.7 as in 6.6.9. TCP's `tcp_rcvbuf_grow` has no UDP
  counterpart.
- **No cache-aware buffer sizing anywhere in the receive path.** Grepping
  `cache_size|llc_size|l3_size` across `net/core/sock.c`, `net/ipv4/udp.c` and
  `net/ipv4/tcp_input.c` returns nothing. `udp_mem` is sized from RAM
  (`limit = nr_free_buffer_pages() / 8`, `udp.c:3880`), never from cache.
- **GRO capacity is unchanged and small**: `MAX_GRO_SKBS 8`
  (`net/core/gro.c:9`), `GRO_HASH_BUCKETS 8`
  (`include/linux/netdevice.h:350`), `UDP_GRO_CNT_MAX 64`
  (`net/ipv4/udp_offload.c:695`). The structure moved from `napi_struct` to
  `struct gro_node`, but the limits did not move. Merge depth therefore still
  degrades roughly as 64/M for M concurrent flows sharing one NAPI.
- `MLX5E_RX_MAX_HEAD` is still 256 (`en.h:84`).
- `__check_object_size` moved to `include/linux/ucopysize.h`.
