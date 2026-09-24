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

## The motivating case, and how it is covered

`udp_sink` asks for 64MB with `SO_RCVBUF`, which is an ordinary thing for a
high-rate receiver to do. Eight of them, with `rmem_max` out of the way, take
about 1GB between them - 55x the L3 - and throughput falls from 47.46 to 13.68.
Every socket made a legal, modest-sounding request, and one of them alone would
have been completely safe. That is the case a per-socket limit cannot express,
and it is why the budget has to be global.

Such a socket never grows through autotuning, so it would be invisible to a
counter of what autotuning has handed out. It is therefore charged for whatever
it holds, and re-charged if that changes. Note carefully what this does and
does not do: **the request is still honoured in full.** Refusing a size an
application asked for outright would break a long-standing expectation. What
the charge buys is that everybody else stops compounding it - which is the
whole difficulty, since 64MB is entirely safe until it is the eighth one.

Measured with one socket asking explicitly and seven leaving it to the kernel,
all eight taking 6 Gbps, at the same 50% budget in both kernels:

| explicit socket | without the charge | with it |
|---|---|---|
| 8MB requested (16MB granted) | 32.15 | **47.41** |
| 64MB requested (128MB granted) | 26.00 | **42.75** |

The per-socket buffers show the mechanism directly: without the charge the
other seven grow to 2 and 4MB on top of the greedy one; with it they stay at
1MB, because the budget is already spent. Disabling the budget entirely gives
16.10 and 17.08 in the two kernels, confirming nothing else differs between
them.

What remains is the greedy socket's own cost. 42.75 against 47.41 is the price
of the 128MB buffer itself, which the kernel declines to override. The
difference between that and 16 Gbps is everyone else not making it worse.

## Giving the allowance back

A budget that is only ever spent is spent once. Measured: a socket that grew to
8MB under 48 Gbps kept all 8MB when its load fell to 4, and a socket arriving
afterwards could reach only 2MB before the allowance ran out. The one holding
the room needed 1MB; the one that needed room could not have it.

TCP sizes its buffer from an RTT clock and can therefore shrink as well as
grow. UDP has no such clock, so the shrink reuses the occupancy signal that
drives growth, with a wide dead band: grow above a half, shrink below an
eighth. Four times' hysteresis keeps a socket sitting near either threshold
from flapping.

The obvious worry is that shrinking loses the buffer just before it is needed
again, since nothing tells a UDP receiver that the sender is about to speed up.
Measured as burst(56G) → lull(4G) → burst(56G), reading only the return:

| | buffer during the lull | on return |
|---|---|---|
| autotune | **released to 1MB** | **55.5** |
| static 1MB | 1MB | 32.0 |
| static 4MB | 4MB held throughout | 55.4 |

Re-growth is fast enough that releasing costs nothing measurable: the same
throughput as a permanently large buffer, without holding the allowance while
idle. At 48 Gbps all three arms return 47.9 and the comparison says nothing —
the buffer only decides throughput above the point where the consumer starts
losing, so that is where this has to be measured.

### Sockets that go quiet

The shrink runs inside the arrival path, so it never sees a socket whose sender
stopped altogether — and that is precisely the socket holding capacity it is
certainly not using. Nothing else in UDP runs periodically, so there is no
existing place to notice it.

With three sockets grown to 4MB and then silenced, a fourth arriving at 56 Gbps
was held at its starting 1MB and delivered **33.4**, against **55.5** once
those three were closed and their grants returned at close.

A workqueue therefore sweeps the UDP hash and reclaims from sockets that are
below the same emptiness threshold the arrival path uses, so nothing is shrunk
here on evidence it would not have shrunk on itself. The sweep is armed only by
a socket actually being refused — the one piece of evidence that the allowance
is contended — and then at most once per quarter second. An uncontended machine
never runs it.

## Counting TCP: measured, and rejected

The budget counts only UDP, while TCP uses the same cache, so subtracting TCP's
memory looked like the obvious next term. It is not. One core, TCP and UDP
together, three runs each:

| | UDP | TCP | total |
|---|---|---|---|
| UDP alone | 39.99 | — | 39.99 |
| both unconstrained | 25.04 | 31.13 | 56.17 |
| TCP capped at 256K | 36.36 | 18.73 | 55.09 |
| **UDP pinned at 1MB** | **21.08** | 37.20 | 58.28 |

The total is ~56 Gbps in every mixed arm: the core is saturated and buffer size
only decides how the two split it. Capping TCP does recover UDP, but that arm
alone would have been read wrongly — it also makes TCP slower, so it cannot
separate cache from CPU. The fourth arm settles it. Subtracting TCP from the
budget forces UDP small, which is exactly that arm, and UDP does *worse* there
than when free to grow (21.08 against 25.04) with no gain in the total. No
cliff is being crossed; there is nothing here for the budget to prevent.

## Multi-queue correctness

Everything above was measured with a single receive queue, which hid two bugs
that only appear once a socket is fed by more than one.

`udp_rcvbuf_autotune()` is called from `__udp_enqueue_schedule_skb()` *before*
it takes the receive queue lock, so it runs unlocked, and a socket with many
senders is delivered from as many queues as those senders hash to. Plain
read-modify-write on the per-socket grant loses updates two ways: two growers
each double from the same value, so the buffer ends at twice what the budget
allowed; and the per-socket total falls behind the global one, which matters at
close, because that is the figure given back. Every lost update leaves the
global counter permanently high, and enough of them spend the allowance for
good — after which nothing on the machine can grow again until reboot. Each
transition is now claimed with a `cmpxchg` on `sk_rcvbuf`, so exactly one
caller moves the counters and the rest take what it left.

The shed mark had the same shape of error: it read the queue from the socket,
via `sk_rx_queue_get()`, which is only maintained for connected sockets. An
unconnected socket — the many-senders case — reads back -1, and the fallback
turned that into queue 0, so every such socket throttled queue 0 no matter
which queue was actually drowning. It now takes the queue from the packet that
could not be queued, which is by construction the one running ahead of its
consumer.

## Sizing from demand rather than from occupancy

Doubling whenever the queue is more than half full answers "is the buffer under
pressure" but never "how much would be enough", so under sustained overload it
keeps doubling until some limit stops it. Measured on one core at 56 Gbit/s
with a single socket and no large bursts arriving, a fixed 1MB buffer carries
48.89 and a fixed 8MB one 40.57 - and autotuning grew into the second figure.
Larger is not better once the arrival rate simply exceeds the consumer: the
queue is full at every size, and the extra only lengthens the time data waits
before it is copied out, by which point it has been evicted.

TCP does not have this problem because it sizes from a measurement rather than
a threshold: `tcp_rcv_space_adjust()` sets the buffer to twice the bytes
received in one RTT. The RTT is there to delimit one turn of the consumer. UDP
has no RTT, but it does have that turn - it is the interval between the queue
filling and emptying again:

    target = 2 x (peak occupancy over one drain-to-drain cycle)

which is the same rule with the same factor and a different clock. It needs no
knowledge of how the NIC is configured, yet it lands on what that configuration
implies: the peak after one moderation window is `rx-frames x packet size` by
construction. And a socket whose consumer never catches up never completes a
cycle, so it never produces a target and never grows - the case that wanted no
growth excludes itself, with no separate test.

The approach is additive, in 64KB steps, keeping the multiplicative decrease.
Under a shared limit whose only feedback is being refused, AIMD converges on an
even split where doubling converges on an arbitrary one. That property is not
demonstrable on this machine - with several sockets sharing one core, none gets
enough rate to run away, and Jain's index stays above 0.999 in every arm we
measured - so it is taken on the established argument rather than claimed as a
result.

### Three bugs, and how each was found

Getting the above to work took four kernels, and none of the three faults was
visible in throughput alone.

**The target was overwritten as soon as it was right.** The drain branch runs
on every arrival below the threshold, not once per cycle, so the first arrival
after a burst set a correct target and the next one - still below the threshold,
with a peak of one packet - replaced it with nearly zero. The buffer never grew
at all; throughput merely looked "somewhat worse" while `ss -uam` showed it
pinned at its starting size for the entire run. A cycle now has to be closed by
both halves: the queue must be seen above half full before a drain completes it.

**Fixing the shrink first was wasted.** The shrink giving back half on every
drain does outrun additive growth, and floors were added so it never goes below
the measured demand - a correct change that moved the result by 1.6 Gbit/s,
because the target being near zero was the actual cause. Diagnose, then fix.

**The budget was counting the wrong half.** It tracked what autotuning handed
out, which leaves the buffer every socket starts with invisible. Eight sockets
at a 1MB default are 8MB of an allowance set at half of an 18MB cache, before a
single grant is made; the eight reached 17.8MB between them and delivered 37.63
where a fixed 1MB buffer delivers 55.70. The whole buffer is now charged once,
on first sight, which also means the shrink floor can no longer be "what was
granted" and is `max(target, rmem_default)` instead.

## Where it stands

One kernel, one setting, two workloads, five runs each, with the driver's
moderation left at its default:

| | one socket at 56G | eight sockets at 7G | worst |
|---|---|---|---|
| fixed 1MB | 32.14 | 55.66 | 32.14 |
| fixed 8MB | 55.41 | 23.17 | 23.17 |
| **autotuned** | **55.32** | **55.58** | **55.32** |

The buffers it arrives at are 4.4MB for the single socket and about 1.1MB each
for the eight, summing just inside the allowance. No fixed number produces both.

Under moderation disabled, where no large bursts arrive, a fixed 1MB buffer is
slightly ahead (48.09 against 45.65, and 49.05 against 45.02): there is nothing
to adapt to, and only the cost of adapting remains.
