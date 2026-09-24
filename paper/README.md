# Paper draft

`paper.tex` — NSDI format, body only, no bibliography yet.

## Building

```
python3 mkfigs.py          # regenerates figs/ from ~/lab/logs
pdflatex paper && pdflatex paper
```

`usenix2019_v3.sty` is in this directory. There is no LaTeX on the control node;
build on a host that has one, or install `texlive-latex-recommended`.

Every figure keeps its `.dat` and `.gp` beside the `.pdf`, so the numbers behind
a plot can be read without rerunning the experiment.

## Where each number comes from

| claim in the paper | script | log prefix |
|---|---|---|
| rx-frames knee moves with the buffer | `sweep_rx_frames.sh` | `rxframes_` |
| the cliff past the ring is the NIC | (inline, `ethtool -S`) | — |
| moderation on/off ladder | `ab_dim_ladder.sh` | `dimladder_` |
| moderation settles and never moves | `probe_dim_trajectory.sh` | `dimtraj_` |
| working set, and CAT moving the knee | `probe_cat_ways.sh` | `catways_` |
| producer/consumer cache sharing | `probe_l2_hypothesis.sh` | — |
| two workloads, one setting | `bench_two_workloads.sh` | `twowl_` |
| return after a lull | `probe_rebound.sh` | `rebound_` |
| idle sockets holding the allowance | `probe_idle_holdout.sh` | `idlehold_` |
| shed's marginal value over autotuning | `ab_shed_marginal.sh` | `shedmarg_` |
| protocol isolation under a shared queue | `ab_protocol_isolation.sh` | `protiso_` |
| many senders, one socket | `sweep_fanin.sh` | `fanin_` |

## Not in the paper, deliberately

Kept here so the omissions are on purpose rather than by oversight.

- **Fairness.** Additive increase is adopted for its convergence argument, but
  no workload on this hardware makes the difference visible: with several
  sockets sharing one core none obtains enough rate to run away, and Jain's
  index over goodput stays above 0.999 in every arm. The paper says so in
  Discussion rather than claiming a result.
- **Counting TCP against the allowance.** Measured and rejected. On one core
  the total is CPU-bound at ~56\,Gbps in every mixed arm and buffer size only
  decides the split; forcing UDP small, which is what subtracting TCP would do,
  makes UDP worse with no gain in the total.
- **MTU 1500.** The mechanism holds but every operating point moves, and we
  have not re-measured the ladder since the tooling changed.
- **A frame count larger than the ring** is a defect in the moderation profiles
  themselves (`lib/dim/net_dim.c` uses fixed constants with no view of the ring).
  It is noted in passing, not claimed as a contribution.
