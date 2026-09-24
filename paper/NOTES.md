# Where the draft stands, and what could still overturn it

Written overnight; read this before the paper.

## The claim as drafted

No static receive-buffer size serves two ordinary workloads on one machine,
because the buffer must simultaneously hold one interrupt-moderation window
(which pushes it up) and fit with every other buffer inside the last-level
cache (which pushes it down). \sys derives it instead, from the same rule TCP
uses with the drain-to-drain interval standing in for the RTT.

## The result that could overturn it

The overload ladder (single socket, 48--80\,Gbps, n=5) has four arms, and the
one we had never run before tonight wins:

| offered | \sys | \sys+shed | fixed 1 MB | **1 MB + shed** |
|---|---|---|---|---|
| 48 G | 47.88 | 47.90 | 33.34 | 47.53 |
| 56 G | 55.02 | 55.49 | 33.97 | 54.72 |
| 64 G | 58.43 | 58.82 | 34.36 | **62.70** |
| 72 G | 54.17 | 58.10 | 36.03 | **61.43** |
| 80 G | 54.90 | 58.62 | 38.73 | **60.91** |

A small fixed buffer with early discard beats adaptive sizing past the ceiling
by 4--6%, and matches it below. The two shed arms differ only in buffer size,
so this is our own cache hand-off result arriving from the other direction:
past the ceiling the queue is full at any capacity, and a larger capacity only
means more data resident and evicted before copy-out.

**What decides the paper** is whether `1 MB + shed` also wins the eight-socket
workload. That arm is in the `main_table` run tonight, along with `8 MB + shed`.
Reasoning says it should not: W2's failure is the buffers' own cache footprint
(8 x 8 MB), and shedding removes work rather than capacity, so it has no
mechanism to help there. If the reasoning holds, the claim stands with a
qualification. If `1 MB + shed` wins both, the honest paper is a different and
simpler one: *keep the buffer small and discard early*, with sizing as the
driver-independent approximation.

Do not write around this. The table will say which.

## The design fault behind it

`target = 2 x peak occupancy over a cycle`, and occupancy is bounded by
`sk_rcvbuf` -- so a larger buffer permits a deeper peak, which raises the
target, which grows the buffer. Nothing but the allowance stops it; it was
measured reaching 9.4 MB on a socket that performed better at 1 MB.

TCP does not have this because `tcp_rcv_space_adjust()` counts bytes *copied to
the application*, which buffer size cannot inflate. We measured the wrong thing.

v16 (written, not built -- building would have disturbed the overnight runs)
accumulates bytes released in `udp_rmem_release()` and uses that instead. Patch
staged at `scratchpad/0009-v16.patch`, design note at `scratchpad/v16_design.md`.
Predictions: W1 settles near 1--2 MB rather than 4--9; the overload gap to
`1 MB + shed` closes; W2 is unchanged, since it already sat at 1.1 MB.

## Results that are solid and independent of the above

These do not depend on which buffer policy wins.

- **The cliff is the cache**, established causally: partitioning L3 to 9 and
  4.5 MiB moves the knee from 10 to 6 to 4 MiB of working set. Socket count is
  irrelevant; the sum is what matters.
- **The hand-off, not the memory, is what a large buffer costs.** Separating
  producer and consumer by shared cache level, sweeping 512 KB to 18 MB gives
  ratios 0.40 (shared L2+L3), 0.61 (L3 only), 0.94 (nothing shared). With no
  shared cache, buffer size barely matters.
- **Three quantities, three parties.** `rx-frames <= ring` (77x more descriptor
  exhaustion at 192 than 128 on a 128-entry ring, none at 1024);
  `rx-frames x pkt <= sk_rcvbuf` (the knee moves 96 -> 128 as the buffer goes
  1 MB -> 8 MB); `ring + sum(buffers) <= LLC` (the 1024-entry ring costs 11
  Gbps). No party sees all three.
- **Moderation's effect changes sign at the knee**: 15--17 points of CPU saved
  below it, 22--33% of throughput lost above it, dropping with the core at 63%
  busy. It does not oscillate -- it settles on (8 us, 128 frames) immediately
  and holds, six runs, zero transitions.
- **Protocol isolation**: discarding raises the aggregate 10--12% when TCP and
  UDP share a queue. Which protocol gains depends on the buffer, so claim the
  total.
- **Fan-in is conditional on GSO**: with it, merge factor is unchanged at 64
  flows; without it, 6.8 -> 1.0, and at 68 Gbps two flows deliver 60.7 against
  sixty-four's 38.7.

## Deliberately omitted

- Fairness. Additive increase is adopted on Chiu & Jain's argument; no workload
  here makes the difference visible (Jain's index > 0.999 in every arm), and
  the unfairness we did see was temporal, which reclamation addresses.
- Counting TCP against the allowance: measured, rejected. On one core the total
  is CPU-bound at ~56 Gbps in every mixed arm; forcing UDP small is what that
  change amounts to, and it makes UDP worse with no gain in the total.
- MTU 1500. Mechanism holds, operating points all move, not re-measured since
  the tooling changed.

## Update, 02:10 — moderation off makes it worse for sizing

`gro_levers` with moderation off, single socket, n=3:

| 56 G | fixed 1 MB | + shed | \sys |
|---|---|---|---|
| app sets UDP_GRO | 48.02 | **52.61** | 45.74 |
| it does not | 35.39 | **43.97** | 34.58 |

With no moderation there are no bursts to absorb, and sizing up only costs
cache — \sys lands *below* the fixed baseline in both rows. Discard wins both.

This is consistent with everything else: sizing pays exactly when there is a
burst to hold, and moderation is what creates the burst. It also narrows the
claim. The honest statement of when \sys helps is:

> when the NIC batches (which is the default) **and** the socket is below the
> core's saturation point.

Outside that box, a small buffer with early discard is better. Inside it, they
are equal on throughput and \sys does it without dropping and without a driver
patch.

## If `1 MB + shed` wins the eight-socket workload too

Restructure as follows rather than defending the current frame.

- **Title/claim**: the receive buffer should be small and the discard early;
  the number to derive is not the buffer but the point at which to stop
  building `skb`s.
- **§3–4 unchanged.** The three-constraint analysis and the cache working-set
  result are what make the recommendation make sense, and neither depends on
  which policy wins. They become the diagnosis, and the recommendation follows
  from them rather than from the controller.
- **§5 becomes the discard**, with the placement argument (drop before the
  `skb`, select by L4 type from the completion descriptor) as the design.
- **§Sizing becomes a section, not the system**: what a kernel can do when the
  driver cannot be changed, reaching parity below the ceiling. Report the
  overload gap honestly as its limit.
- **Keep the allowance** either way. It is what stops eight sockets from each
  taking a reasonable buffer and collectively thrashing, and discard has no
  mechanism for that. If this is the only thing left standing from the sizing
  work, it is still a result: *a per-socket limit cannot express a shared
  cache*.

## VERDICT, 03:20 — the claim is refuted, and the paper is better for it

`main_table`, moderation on, n=10 in progress (rows below are the first 4--6):

| configuration | W1 Gb/s | loss | W2 Gb/s | loss |
|---|---|---|---|---|
| fixed 1 MB | 35.5 | 36.6% | 55.7 | 0.6% |
| fixed 8 MB | 55.5 | 1.0% | 22.7 | 58% |
| fixed 8 MB + shed | 55.5 | 0.9% | **29.4** | 47% |
| **fixed 1 MB + shed** | **54.3** | 0.3–6.5% | **55.8** | 0.35% |
| \sys (n=5) | 55.3 | — | 55.6 | — |

**A fixed 1 MB buffer with driver-side discard serves both workloads.** So "no
static size works" is false as stated, and adaptive sizing is not the answer.

But the second row pair is what makes this a paper rather than a retraction:
**discarding cannot rescue an over-large buffer.** 8 MB x 8 gives 22.7 without
discard and 29.4 with — an improvement, and still half of what 1 MB + discard
gets, still losing 47%. Removing work does not remove capacity, and capacity is
what thrashes the cache.

### The paper this makes

> **Cap the receive buffer from the cache, and discard the excess at the driver.**

Two mechanisms, no controller, both justified by the same measurement:

1. **The diagnosis is unchanged and is the contribution.** Three quantities set
   by three parties; the cliff is the LLC, shown causally with CAT; what a large
   buffer costs is the producer-to-consumer hand-off, not the memory. This is
   what makes the recommendation follow rather than being a heuristic.
2. **The answer is not a bigger buffer.** Past the point where arrivals exceed
   the consumer, more buffer means more eviction. Stop building `skb`s instead.
3. **Something must still bound the buffer**, because discarding cannot undo a
   large one — the row above is the evidence. The cache-derived global allowance
   survives as a **cap**, not as a controller: its job is to stop eight
   reasonable per-socket choices from summing past the cache.

### What to do with the adaptive sizing

Report it as a negative result, briefly and without defensiveness. We built it,
it works, it reaches parity below the ceiling and loses above it, and it is not
better than a cap plus discard. That is worth saying because it locates the
problem: it is not "find the right size", it is "stop the sizes summing too
large, and stop doing work you will throw away".

The self-inflating estimate (`target = 2 x peak`, peak bounded by `sk_rcvbuf`)
belongs in that section as the reason it could not have worked as built. v16
would fix the estimator but would not change the conclusion, because the
conclusion is that the estimator is not what was needed.
