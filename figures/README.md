# Figures

`scripts/make_figures.py` regenerates everything here from the raw logs under
`~/lab/logs`. Each PNG keeps its `.dat` and `.gp` alongside it, so a figure can
be re-plotted or tweaked without re-running an experiment. The source log
directory is printed in the bottom-left corner of every plot.

## A caution about the x-axes

Two different load generators appear in these figures and they are **not
interchangeable**:

- **iperf3** paces with `clock_nanosleep` per timer tick. When the target rate
  needs less than one datagram per tick it sends one every N.NN ticks, and the
  resulting burst train overflows the socket buffer at rates well below the
  ceiling. Anything measured this way below saturation carries phantom loss.
- **udp_blast → udp_sink** paces on a byte budget: the next send is released
  when the wire would have drained everything sent so far. No quantisation.

`fig05` puts them side by side; it is the reason the later experiments switched
tools. Figures 01-03 and 07 predate the switch and are iperf3-based — their
*relative* comparisons hold (both arms share the artifact) but the absolute
shape below the ceiling does not.

## The figures

| file | x axis | what it shows |
|---|---|---|
| `fig01_rcvbuf_by_ring_blast` | sk_rcvbuf | Under blast the buffer curve is monotone at ring 1024 but develops a peak at ring 256 — we had been measuring only the right-hand tail |
| `fig02_rcvbuf_by_ring_46g` | sk_rcvbuf | Same at a fixed 46 Gbit/s, across three ring sizes |
| `fig03_rate_ladder_by_ring` | offered rate | UDP ceiling moves 48.1 → 56.8 Gbit/s when the ring drops from 1024 to 128; TCP's 51.4 marked for reference |
| **`fig04_shed_vs_rate`** | offered rate | **The main result.** Without shed, offering 25% above the ceiling costs 15% of goodput; with shed the curve plateaus. Clean tools, N=10 |
| `fig05_tool_comparison` | offered rate | The same receiver under both generators — iperf3 loses 6% at 44 Gbit/s where udp_blast loses 0.02% |
| **`fig06_cache_sharing`** | sk_rcvbuf | **The mechanism.** Growing the buffer costs 60% when producer and consumer share an L2, 39% when they share only L3, and 6% when they share nothing |
| `fig07_mtu1500_rcvbuf` | sk_rcvbuf | At MTU 1500 the curve is flat above 512KB — the buffer optimum only exists when the receiver is overrun-bound |
| `fig08_shed_window` | shed window | The optimum moves with load but only slightly, while being 8x too long costs 67% — why the window is fixed short rather than adapted |
| `fig09_config_levers` | offered rate | Shrinking the mlx5 head copy and dropping the usercopy check, before and after |
| **`fig10_working_set`** | working set | **The cliff sits at the L3 size, with L3 miss rising in mirror image** |
| **`fig11_cat_ways`** | working set | **Masking L3 ways with CAT drags the knee down in proportion — correlation becomes cause** |
| `fig12_multiflow_working_set` | working set | One socket and eight collapse at the same aggregate |
| **`fig13_final_single`** | offered rate | **The summary run: every lever is worth nothing below the ceiling and up to +31% past it** |

## Parameters actually swept

| parameter | range | figures |
|---|---|---|
| RX ring size (`ethtool -G rx`) | 128, 256, 1024 | 01, 02, 03 |
| Receive buffer (`net.core.rmem_default`) | 208KB – 18MB | 01, 02, 06, 07 |
| Offered rate | 40 – 72 Gbit/s | 03, 04, 05 |
| Driver shed (`net.ipv4.udp_rx_shed`) | off / on | 04 |
| Producer/consumer core placement | same / same-socket / cross-socket | 06 |
| MTU | 1500, 9000 | 07 |
| Shed window (`net.ipv4.udp_rx_shed_us`) | pending sweep | — |
