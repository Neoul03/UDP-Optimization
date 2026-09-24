#!/usr/bin/env python3
"""Build the paper's figures from the raw logs.

Each figure is emitted as a .dat next to its .gp so the numbers behind a plot
can be read without rerunning anything, which is the same convention the
lab's figures/ directory already uses.
"""
import os, re, subprocess, glob, sys

OUT = os.path.dirname(os.path.abspath(__file__)) + "/figs"
os.makedirs(OUT, exist_ok=True)

COMMON = """set terminal pdfcairo font "Helvetica,9" size %s
set output "%s"
set style line 1 lc rgb '#1b4965' lw 2 pt 7 ps 0.5
set style line 2 lc rgb '#c1666b' lw 2 pt 5 ps 0.5
set style line 3 lc rgb '#4a7c59' lw 2 pt 9 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2 pt 11 ps 0.6
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set xtics nomirror
set ytics nomirror
set key top left reverse Left samplen 1.5
"""

def newest(pat):
    ds = sorted(glob.glob(pat), reverse=True)
    return ds[0] if ds else None

def write(name, dat, gp):
    open(f"{OUT}/{name}.dat", "w").write(dat)
    open(f"{OUT}/{name}.gp", "w").write(gp)
    r = subprocess.run(["gnuplot", f"{OUT}/{name}.gp"], capture_output=True, text=True)
    print(f"{name}: {'ok' if r.returncode == 0 else r.stderr.strip()[:200]}")

# ---------------------------------------------------------------- fig 1
# rx-frames sweep at three buffer policies.  The knee moves with the buffer,
# and the adaptive controller parks at 128 - to the right of where 1MB fails.
def fig_frames():
    d = newest(os.path.expanduser("~/lab/logs/rxframes_*"))
    if not d: return print("fig_frames: no data")
    rows = {}
    for ln in open(f"{d}/raw.txt"):
        f = ln.split()
        if len(f) < 4: continue
        rows.setdefault(f[0], {}).setdefault(int(f[1]), []).append(float(f[2]))
    order = ["fixed1M", "fixed8M", "autotune"]
    frames = sorted({k for v in rows.values() for k in v})
    dat = "# frames  " + "  ".join(order) + "\n"
    for fr in frames:
        vals = []
        for a in order:
            v = rows.get(a, {}).get(fr, [])
            vals.append(f"{sum(v)/len(v):.2f}" if v else "NaN")
        dat += f"{fr}  " + "  ".join(vals) + "\n"
    gp = COMMON % ("3.3in,2.0in", f"{OUT}/fig_frames.pdf") + """
set xlabel "NIC moderation frame count (rx-frames)"
set ylabel "goodput (Gbit/s)"
set logscale x 2
set xrange [14:300]
set yrange [0:55]
set arrow from 128,0 to 128,55 nohead lc rgb '#999999' dt 2
set label "driver settles here" at 128,52 right offset -0.5,0 tc rgb '#555555' font ",8"
plot "%s/fig_frames.dat" u 1:2 w lp ls 2 t "fixed 1 MB", \\
     "" u 1:3 w lp ls 4 t "fixed 8 MB", \\
     "" u 1:4 w lp ls 1 t "Ripple"
""" % OUT
    write("fig_frames", dat, gp)

# ---------------------------------------------------------------- fig 2
# The moderation ladder.  Effect changes sign at the knee: below it the
# controller saves CPU at equal throughput, above it the machine drops with
# the CPU idle.
def fig_moderation():
    d = newest(os.path.expanduser("~/lab/logs/dimladder_*"))
    if not d: return print("fig_moderation: no data")
    rows = {}
    for ln in open(f"{d}/raw.txt"):
        f = ln.split()
        if len(f) < 4: continue
        rows.setdefault(f[0], {}).setdefault(int(f[1]), []).append((float(f[2]), float(f[3])))
    rates = sorted({k for v in rows.values() for k in v})
    dat = "# offered  off_got off_busy  on_got on_busy\n"
    for r in rates:
        line = [str(r)]
        for a in ("off", "on"):
            v = rows.get(a, {}).get(r, [])
            if v:
                line += [f"{sum(x[0] for x in v)/len(v):.2f}", f"{sum(x[1] for x in v)/len(v):.0f}"]
            else:
                line += ["NaN", "NaN"]
        dat += "  ".join(line) + "\n"
    gp = COMMON % ("3.3in,2.0in", f"{OUT}/fig_moderation.pdf") + """
set xlabel "offered rate (Gbit/s)"
set ylabel "goodput (Gbit/s)"
set y2label "core busy (pct)"
set y2tics nomirror
set ytics nomirror
set yrange [25:55]
set y2range [40:105]
set key bottom left
plot "%s/fig_moderation.dat" u 1:2 w lp ls 1 t "goodput, moderation off", \\
     "" u 1:4 w lp ls 2 t "goodput, moderation on", \\
     "" u 1:3 axes x1y2 w l ls 1 dt 2 t "busy, off", \\
     "" u 1:5 axes x1y2 w l ls 2 dt 2 t "busy, on"
""" % OUT
    write("fig_moderation", dat, gp)

# ---------------------------------------------------------------- fig 3
# Two workloads, one setting.  The point of the paper in one plot.
def fig_workloads():
    d = newest(os.path.expanduser("~/lab/logs/twowl_*"))
    if not d or not os.path.exists(f"{d}/raw.txt"): return print("fig_workloads: no data")
    rows = {}
    for ln in open(f"{d}/raw.txt"):
        f = ln.split()
        if len(f) < 5 or f[0] != "on": continue
        rows.setdefault(f[1], {}).setdefault(f[2], []).append(float(f[3]))
    order = [("s1M", "fixed 1 MB"), ("s1M_shed", "1 MB + shed"),
             ("s8M", "fixed 8 MB"), ("auto", "Ripple")]
    dat = "# idx label W1 W2\n"
    for i, (k, lab) in enumerate(order):
        w1 = rows.get(k, {}).get("W1", [0]); w2 = rows.get(k, {}).get("W2", [0])
        dat += f'{i} "{lab}" {sum(w1)/len(w1):.2f} {sum(w2)/len(w2):.2f}\n'
    gp = COMMON % ("3.3in,1.9in", f"{OUT}/fig_workloads.pdf") + """
set style data histogram
set style histogram cluster gap 1
set style fill solid 0.85 border -1
set boxwidth 0.9
set ylabel "goodput (Gbit/s)"
set yrange [0:60]
set xtics scale 0
set key top center horizontal
plot "%s/fig_workloads.dat" u 3:xtic(2) ls 1 t "W1: one socket, 56 Gb/s", \\
     "" u 4 ls 2 t "W2: eight sockets, 7 Gb/s each"
""" % OUT
    write("fig_workloads", dat, gp)

# ---------------------------------------------------------------- fig 4
# Working set against goodput, with the cache moved by CAT.  Reuses the
# earlier sweep; the cliff tracks the partition, which is the causal test.
def fig_workingset():
    src = os.path.expanduser("~/lab/figures/fig11.dat")
    if not os.path.exists(src): return print("fig_workingset: no data")
    dat = open(src).read()
    gp = COMMON % ("3.3in,2.0in", f"{OUT}/fig_workingset.pdf") + """
set xlabel "working set: ring pages + {/Symbol S} sk_rcvbuf (MiB)"
set ylabel "goodput (Gbit/s)"
set logscale x 2
set key bottom left
plot "%s/fig_workingset.dat" u 1:2 w lp ls 1 t "L3 = 18 MiB", \\
     "" u 1:4 w lp ls 2 t "L3 = 9 MiB (CAT)", \\
     "" u 1:6 w lp ls 4 t "L3 = 4.5 MiB (CAT)"
""" % OUT
    write("fig_workingset", dat, gp)

# ---------------------------------------------------------------- fig 5
# Fan-in.  The flow-count effect exists only when the senders do not use
# segmentation offload, because GSO lays one flow's packets contiguously.
def fig_fanin():
    rows = {}
    for segs in (7, 1):
        d = newest(os.path.expanduser(f"~/lab/logs/fanin_s{segs}_*"))
        if not d: continue
        for ln in open(f"{d}/raw.txt"):
            f = ln.split()
            if len(f) < 4: continue
            rows.setdefault(segs, {}).setdefault(int(f[0]), []).append(
                (float(f[1]), float(f[2]) / 8972.0, float(f[3])))
    if not rows: return print("fig_fanin: no data")
    flows = sorted({k for v in rows.values() for k in v})
    dat = "# flows  gso_merge gso_busy  nogso_merge nogso_busy\n"
    for fl in flows:
        line = [str(fl)]
        for segs in (7, 1):
            v = rows.get(segs, {}).get(fl, [])
            line += [f"{sum(x[1] for x in v)/len(v):.2f}", f"{sum(x[2] for x in v)/len(v):.0f}"] if v else ["NaN", "NaN"]
        dat += "  ".join(line) + "\n"
    gp = COMMON % ("3.3in,2.0in", f"{OUT}/fig_fanin.pdf") + """
set xlabel "concurrent sender flows into one socket"
set ylabel "GRO merge factor (datagrams per skb)"
set y2label "core busy (pct)"
set y2tics nomirror
set logscale x 2
set yrange [0:8]
set y2range [40:70]
set key bottom left
plot "%s/fig_fanin.dat" u 1:2 w lp ls 1 t "merge, senders use GSO", \\
     "" u 1:4 w lp ls 2 t "merge, they do not", \\
     "" u 1:5 axes x1y2 w l ls 2 dt 2 t "busy, they do not"
""" % OUT
    write("fig_fanin", dat, gp)

for f in (fig_frames, fig_moderation, fig_workloads, fig_workingset, fig_fanin):
    try: f()
    except Exception as e: print(f"{f.__name__}: {e}")
