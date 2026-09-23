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
budget = LLC_bytes * udp_rmem_cache_pct / 100;
grow only while udp_rcvbuf_granted + grant <= budget;
```

Three choices worth stating.

*Bound granted capacity, with a global counter.* `udp_rcvbuf_granted` is an
`atomic_long_t` holding what autotuning has handed out across every UDP socket,
charged before the grant is made so concurrent growers see each other at once,
with a per-socket record in `struct udp_sock` so it can be returned on close.
The socket count never enters it, which matters because the measurements say
the count is irrelevant and only the sum matters. See below for why the
kernel's existing `sk_memory_allocated()` will not serve.

*The cache size is read at runtime.* A `late_initcall` walks `cacheinfo` for
the highest DATA or UNIFIED level; the enqueue path runs in softirq and cannot
take the cpu hotplug lock, so the value is resolved once and only read
afterwards. `mm/page_alloc.c` uses the same interface. On this receiver it
reports 18432 KiB, matching what the CAT experiment measured independently - so
nothing is hardcoded, and a machine with a 39MB last-level cache gets a
proportionally larger budget without being told.

*The fraction is left to the operator.* The kernel cannot see how much of the
cache is already committed: NIC rings are invisible from here - on mlx5 at a
9000-byte MTU a 1024-entry ring pins 16MB - and on a busy machine other cores
compete for the same cache. Default 50%.

## Where it stands

Eight sockets, 48 Gbps offered in total, one receiving core, three runs each.

| | total goodput | UDP memory held |
|---|---|---|
| autotune off, 1MB by hand | **47.83** | 0.36 MB |
| **autotune + budget** | **47.21** | 0.48 MB |
| autotune, budget disabled | 16.22 | 506 MB |

The budget lands within 1.3% of the hand-tuned buffer while the falsification
arm collapses, so the gain is the budget's doing. Per-socket buffers come out
mixed — some at 1MB, some at 2MB, some at 4MB — which is the intended
behaviour: whoever asks first gets the room, and the *sum* is what is bounded.

### What has to be counted

Getting this right took three attempts, and the difference was not the idea but
the quantity.

| version | bounded quantity | result |
|---|---|---|
| v6 | `sk_memory_allocated()` | 31.24 |
| v7 | + charge the prospective grant | 30.52 |
| **v8** | **granted capacity** | **47.21** |

Bounding `sk_memory_allocated()` looks natural — the kernel already maintains
it, so no new state is needed — but it counts memory *already queued*, and
while the consumer keeps up the queues sit nearly empty: 0.36MB held against
8MB of granted capacity. The budget therefore does not bite until the queues
have grown deep, by which point the buffers behind them are several doublings
too large. Occupancy follows capacity, not the other way round.

So v8 keeps a global `atomic_long_t` of what autotuning has handed out, charged
before the grant is made so that concurrent growers see each other immediately,
with a per-socket record in `struct udp_sock` so the grant can be returned on
close. Three consecutive runs give 47.4, 47.37 and 46.85, so nothing leaks.

## The motivating case, and what is still uncovered

`udp_sink` asks for 64MB with `SO_RCVBUF`, which is an ordinary thing for a
high-rate receiver to do. Eight of them, with `rmem_max` out of the way, take
about 1GB between them - 55x the L3 - and throughput falls from 47.46 to 13.68.
Every socket made a legal, modest-sounding request, and one of them alone would
have been completely safe. That is the case a per-socket limit cannot express,
and it is why the budget has to be global.

**The budget does not cover it.** `SO_RCVBUF` sets `SOCK_RCVBUF_LOCK`, and
autotuning skips such sockets deliberately, so no grant is ever charged for
them and they are invisible to `udp_rcvbuf_granted`. An application that asks
explicitly still gets what it asks for, bounded only by `rmem_max`, and it can
still exhaust the cache on its own.

This is a real gap and worth being plain about: the budget currently protects
applications that let the kernel size their buffers from *each other*, not from
an application that sizes its own. Closing it means either counting explicit
`SO_RCVBUF` grants against the same budget - which means sometimes refusing a
request the application made deliberately - or reporting the budget back to
userspace so an application can size itself against it. The first breaks a
long-standing expectation; the second needs an interface. Neither is decided
here.
