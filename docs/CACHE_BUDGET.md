# A global receive budget sized from the cache

## What the measurements established

Three results from the single-core receive study constrain the design.

**The working set is the only predictor.** Neither the Rx ring size nor
`sk_rcvbuf` matters on its own; their sum does. A 128-entry ring with a 16MB
buffer (18MiB total) delivers 33.20 Gbps, and a 1024-entry ring with 4MB
(20MiB) delivers 33.05 — completely different settings, same result. Below
about 17MiB the curve is flat at 44.

**The threshold is the last-level cache, causally.** PMU counters put L3
load-misses at 0.0% up to a 6MiB working set and 14.3% at 18MiB, with IPC
falling from 1.12 to 1.02. Masking L3 ways through resctrl then moves the knee
with the cache: at 18, 9 and 4.5MiB of L3 it sits at a 10, 6 and 4MiB working
set.

**Socket count is irrelevant.** Eight sockets at 2MB each (18MiB total)
collapse to 30.37; one socket at 16MB (also 18MiB) to 33.20. At 34MiB they are
25.39 and 25.89.

## Why a per-socket limit cannot express this

`sk_rcvbuf` bounds one socket. It cannot say "4MB is fine for one of you and
ruinous for eight of you", because no socket knows how many others there are.
The only global limit UDP has is `udp_mem`, and it is sized from RAM
(`limit = nr_free_buffer_pages() / 8`, `net/ipv4/udp.c`), which is unrelated to
the quantity that governs throughput. Grepping `cache_size|llc_size|l3_size`
across `net/core/sock.c`, `net/ipv4/udp.c` and `net/ipv4/tcp_input.c` returns
nothing, in every kernel up to 7.2.7.

## The implementation

```c
budget_pages = (LLC_bytes * udp_rmem_cache_pct / 100) >> PAGE_SHIFT;
grow only while sk_memory_allocated(sk) + (grant >> PAGE_SHIFT) < budget_pages;
```

Three choices worth stating.

*No socket counting.* `sk_memory_allocated()` already aggregates across every
UDP socket, which is exactly the quantity the measurements point at, so the
bound needs no new global state and stays correct when sockets hold different
amounts.

*The cache size is read at runtime.* A `late_initcall` walks `cacheinfo` for
the highest DATA or UNIFIED level; the enqueue path runs in softirq and cannot
take the cpu hotplug lock, so the value is resolved once and only read
afterwards. `mm/page_alloc.c` uses the same interface. On this receiver it
reports 18432 KiB, matching what the CAT experiment measured independently.

*The fraction is left to the operator.* The kernel cannot see how much of the
cache is already committed: NIC rings are invisible from here — on mlx5 at a
9000-byte MTU a 1024-entry ring pins 16MB — and on a busy machine other cores
compete for the same cache. Default 50%.

## Where it stands

Eight sockets, 48 Gbps offered in total, one receiving core.

| | total goodput | UDP memory |
|---|---|---|
| autotune off (1MB fixed) | **47.83** | 0.6 MB |
| autotune + budget at 50% | 31.24 | 19.6 MB |
| autotune, budget disabled | 17.90 | 505 MB |

The bound works: it holds the aggregate 26× lower than unbounded and is worth
+75% against the falsification arm, which does collapse, so the gain is the
budget's doing.

It is not yet tight enough. The target was 9MB and the measured aggregate is
19.6MB, which with the ring's 2MB puts the total past the 18MiB cliff — so a
hand-set 1MB buffer still beats it. The cause is that
`sk_memory_allocated()` reports memory already committed, so a doubling does
not appear in it until the larger queue has filled; eight sockets can all read
the aggregate as under budget, all double, and only then push it over.
Charging the prospective grant is the current fix under measurement.

## The motivating case, and a limit

`udp_sink` asks for 64MB with `SO_RCVBUF`, which is an ordinary thing for a
high-rate receiver to do. Eight of them, with `rmem_max` out of the way, take
about 1GB between them — 55× the L3 — and throughput falls from 47.46 to 13.68.
Every socket made a legal, modest-sounding request, and one of them would have
been completely safe.

That same case is beyond this patch's reach: `SO_RCVBUF` sets
`SOCK_RCVBUF_LOCK`, and autotuning skips such sockets deliberately, so the
budget never gets to refuse them. What it does do is count them —
`sk_memory_allocated()` includes their queues — so a locked socket that eats
the budget stops every other socket from growing. That is the intended
compromise: the kernel does not override an explicit request, but it does stop
letting everyone else compound the problem.
