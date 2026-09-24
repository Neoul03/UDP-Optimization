# Three quantities, three parties, one constraint

The receive buffer cannot be chosen correctly by anyone who is allowed to choose
it. This is not an argument about convenience; three separate quantities have to
satisfy three coupled constraints, and each is set by a party that cannot see
the other two.

| quantity | who sets it | what they cannot see |
|---|---|---|
| ring size | administrator, or the driver default | how much cache it occupies |
| `rx-frames` | **the driver's moderation, at run time** | the ring size, and every socket buffer |
| `sk_rcvbuf` | the application, or the administrator | what `rx-frames` currently is |

The constraints:

1. `rx-frames <= ring` — otherwise the NIC runs out of descriptors before the
   interrupt it is waiting for.
2. `rx-frames x packet size <= sk_rcvbuf` — otherwise the socket queue overflows
   on a burst the consumer has not reached yet.
3. `ring bytes + sum of sk_rcvbuf <= last level cache` — otherwise the receive
   path thrashes the cache it depends on.

Raising the ring relieves (1) and tightens (3). Raising the buffer relieves (2)
and tightens (3). And the left-hand side of (2) is changed at run time by code
the application has no view of.

## What each constraint costs when it binds

Measured on one core, 100Gb ConnectX-5, MTU 9000, 48 Gbit/s offered, five runs
per point, with adaptive moderation disabled so `rx-frames` could be set
directly. Every figure below has a standard deviation of about 0.00; none of
this is noise.

**Constraint 2, the socket queue.** Sweeping `rx-frames` at a fixed `rx-usecs`
of 8, the knee moves with the buffer:

| rx-frames | 1MB | 8MB | autotuned |
|---|---|---|---|
| 16 / 32 / 64 | 47.98 | 47.97 | 47.98 |
| 96 | **38.04** | 47.98 | 47.98 |
| 128 | **28.93** | 47.86 | 47.89 |
| 192 / 256 | 20.0 | 39.6 | 39.6 |

**Constraint 1, the descriptors.** The collapse past 128 has a different cause.
With a 128-entry ring, `rx_out_of_buffer` gains 14,958 over a run at
`rx-frames` 128 and 1,161,830 at 192 - seventy-seven times as many - and with a
1024-entry ring it gains nothing at either. The NIC cannot hold a moderation
window larger than its ring.

**Constraint 3, the cache.** The larger ring is not free. At `rx-frames` 128
with an 8MB buffer, a 128-entry ring carries 47.86 and a 1024-entry ring 36.86:
eleven gigabits for the 16MB of descriptor pages the larger ring pins in a
cache of eighteen.

## Where moderation lands, and why it is not wrong

Adaptive moderation settles immediately on `rx-usecs` 8 and `rx-frames` 128 and
stays there - six runs, zero transitions. That is not an oscillation to be
damped, and it is not a bad choice in itself: with an 8MB buffer it costs
nothing, and below the knee it saves real work, holding throughput equal while
taking fifteen to seventeen points less CPU:

| offered | moderation off | moderation on | busy off | busy on |
|---|---|---|---|---|
| 32G | 31.99 | 31.99 | 65% | **50%** |
| 40G | 39.98 | 39.98 | 77% | **60%** |
| 44G | 43.98 | **37.57** | 84% | 61% |
| 48G | 47.93 | **37.60** | 91% | 68% |
| 56G | 48.92 | **32.99** | 100% | 63% |

The effect changes sign at the knee. Above it the machine drops packets with
the CPU idle - 63% busy while delivering 32.99 - which is not exhaustion but a
buffer that cannot hold what one moderation window delivers. The choice of 128
is wrong only relative to a buffer that was sized without knowing it.

This also explains why an earlier measurement of ours found moderation to be a
non-factor: it was taken at 46 Gbit/s, which is inside the transition, where
the coefficient of variation is 8.8% to 19.7% and repeated runs genuinely do
come out both ways. The measurement was right and the conclusion drawn from one
operating point was not.

## The consequence

The application is asked to pick a number that depends on a quantity the kernel
changes underneath it. It cannot, and neither can the administrator. What the
kernel can do is observe the consequence rather than read the setting: the peak
the queue reaches over one fill-and-drain cycle is `rx-frames x packet size` by
construction, without anyone having to look it up. That is what the autotuning
in [CACHE_BUDGET.md](CACHE_BUDGET.md) measures.

## A separate observation, for upstream

`rx-frames` larger than the ring is straightforwardly wrong, and the moderation
profiles in `lib/dim/net_dim.c` are fixed constants with no view of the ring:
`rx-usecs` 1/8/64/128/256 against `NET_DIM_DEFAULT_RX_CQ_PKTS_FROM_EQE` of 256.
On a 128-entry ring the chosen 128 sits exactly at the limit and the next
profile up is past it. Clamping the frame count to the ring would be a small
change, and it is independent of everything else here.
