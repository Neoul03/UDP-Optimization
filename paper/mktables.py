#!/usr/bin/env python3
"""Emit the evaluation tables from the overnight logs into gen/.

The paper \\input{}s these, so re-running this after a measurement updates the
draft without anyone retyping a number.  Each table carries n so a reader can
see what it rests on.
"""
import os, glob, subprocess, statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = f"{HERE}/gen"; os.makedirs(GEN, exist_ok=True)

def newest(pat):
    ds = sorted(glob.glob(os.path.expanduser(pat)), reverse=True)
    for d in ds:
        if os.path.exists(f"{d}/raw.txt") and os.path.getsize(f"{d}/raw.txt") > 0:
            return d
    return None

def load(d, ncol):
    rows = []
    for ln in open(f"{d}/raw.txt"):
        f = ln.split()
        if len(f) >= ncol: rows.append(f)
    return rows

def mean(v): return sum(v)/len(v) if v else float('nan')

def emit(name, body):
    open(f"{GEN}/{name}.tex", "w").write(body)
    print(f"{name}: written")

# ------------------------------------------------------------ shed marginal
def t_shedmarg():
    d = newest("~/lab/logs/shedmarg_*")
    if not d: return print("shedmarg: no data")
    agg = {}
    for dim, arm, rate, got, busy in load(d, 5):
        agg.setdefault((dim, arm), {}).setdefault(int(rate), []).append(float(got))
    rates = sorted({r for v in agg.values() for r in v})
    def row(dim, arm, label):
        cells = []
        for r in rates:
            v = agg.get((dim, arm), {}).get(r, [])
            cells.append(f"{mean(v):.1f}" if v else "--")
        return f"{label} & " + " & ".join(cells) + r" \\"
    n = max((len(v) for a in agg.values() for v in a.values()), default=0)
    out = [r"\begin{table}[t]", r"\centering", r"\small",
           r"\begin{tabular}{@{}l" + "r"*len(rates) + r"@{}}", r"\toprule",
           "offered (Gb/s) & " + " & ".join(str(r) for r in rates) + r" \\", r"\midrule",
           r"\multicolumn{%d}{@{}l}{\emph{moderation on (the default)}} \\" % (len(rates)+1),
           row("on","auto",r"\quad \sys"), row("on","auto_shed",r"\quad \sys + shed"),
           row("on","s1M",r"\quad fixed 1\,MB"), row("on","s1M_shed",r"\quad fixed 1\,MB + shed"),
           r"\midrule",
           r"\multicolumn{%d}{@{}l}{\emph{moderation off}} \\" % (len(rates)+1),
           row("off","auto",r"\quad \sys"), row("off","auto_shed",r"\quad \sys + shed"),
           row("off","s1M",r"\quad fixed 1\,MB"), row("off","s1M_shed",r"\quad fixed 1\,MB + shed"),
           r"\bottomrule", r"\end{tabular}",
           r"\caption{Goodput past the ceiling, $n=%d$ per point. Sizing carries the" % n,
           r"load up to the ceiling; only shedding changes anything beyond it.}",
           r"\label{tab:shedmarg}", r"\end{table}"]
    emit("shedmarg", "\n".join(out) + "\n")
    # companion plot
    dat = "# rate " + " ".join(f"{d_}_{a}" for d_ in ("on","off") for a in ("auto","auto_shed")) + "\n"
    for r in rates:
        cells = [f"{mean(agg.get((d_,a),{}).get(r,[])):.2f}" if agg.get((d_,a),{}).get(r) else "NaN"
                 for d_ in ("on","off") for a in ("auto","auto_shed")]
        dat += f"{r} " + " ".join(cells) + "\n"
    open(f"{HERE}/figs/fig_shedmarg.dat","w").write(dat)
    gp = f'''set terminal pdfcairo font "Helvetica,9" size 3.3in,2.0in
set output "{HERE}/figs/fig_shedmarg.pdf"
set style line 1 lc rgb '#1b4965' lw 2 pt 7 ps 0.5
set style line 2 lc rgb '#c1666b' lw 2 pt 5 ps 0.5
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set xtics nomirror
set ytics nomirror
set xlabel "offered rate (Gbit/s)"
set ylabel "goodput (Gbit/s)"
set key bottom left reverse Left samplen 1.5
plot "{HERE}/figs/fig_shedmarg.dat" u 1:2 w lp ls 1 t "Ripple", \\
     "" u 1:3 w lp ls 2 t "Ripple + shed", \\
     "" u 1:4 w lp ls 1 dt 2 t "Ripple, mod. off", \\
     "" u 1:5 w lp ls 2 dt 2 t "Ripple + shed, mod. off"
'''
    open(f"{HERE}/figs/fig_shedmarg.gp","w").write(gp)
    subprocess.run(["gnuplot", f"{HERE}/figs/fig_shedmarg.gp"], capture_output=True)

# ------------------------------------------------------------ protocol iso
def t_protiso():
    d = newest("~/lab/logs/protiso_*")
    if not d: return print("protiso: no data")
    agg = {}
    for arm, u, t in load(d, 3):
        agg.setdefault(arm, []).append((float(u), float(t)))
    names = [("s1M", r"fixed 1\,MB"), ("s1M_shed", r"fixed 1\,MB + shed"),
             ("auto", r"\sys"), ("auto_shed", r"\sys + shed")]
    rows = []
    for k, lab in names:
        v = agg.get(k, [])
        if not v: continue
        u = mean([x[0] for x in v]); t = mean([x[1] for x in v])
        rows.append(f"{lab} & {u:.1f} & {t:.1f} & {u+t:.1f}" + r" \\")
    n = max((len(v) for v in agg.values()), default=0)
    out = [r"\begin{table}[t]", r"\centering", r"\small",
           r"\begin{tabular}{@{}lrrr@{}}", r"\toprule",
           r"configuration & UDP & TCP & total \\", r"\midrule", *rows,
           r"\bottomrule", r"\end{tabular}",
           r"\caption{A UDP flow and a TCP flow sharing one receive queue and one",
           r"core, $n=%d$. Discarding raises the aggregate by 10--12 percent in both" % n,
           r"buffer configurations; which protocol collects the gain depends on",
           r"the buffer, so we claim the total and not the split.}",
           r"\label{tab:protiso}", r"\end{table}"]
    emit("protiso", "\n".join(out) + "\n")

# ------------------------------------------------------------ GRO levers
def t_grolevers():
    outs = []
    for dim in ("on", "off"):
        d = newest(f"~/lab/logs/grolevers_dim{dim}_*")
        if not d: continue
        agg = {}
        for lbl, mode, rate, got, busy in load(d, 5):
            agg.setdefault((lbl, mode), {}).setdefault(int(rate), []).append(float(got))
        rates = sorted({r for v in agg.values() for r in v})
        if not rates: continue
        def row(lbl, mode, label):
            return f"{label} & " + " & ".join(
                f"{mean(agg.get((lbl,mode),{}).get(r,[])):.1f}" if agg.get((lbl,mode),{}).get(r) else "--"
                for r in rates) + r" \\"
        outs += [r"\begin{table}[t]", r"\centering", r"\small",
                 r"\begin{tabular}{@{}l" + "r"*len(rates) + r"@{}}", r"\toprule",
                 "offered (Gb/s) & " + " & ".join(str(r) for r in rates) + r" \\", r"\midrule",
                 r"\multicolumn{%d}{@{}l}{\emph{application sets UDP\_GRO}} \\" % (len(rates)+1),
                 row("base_noshed","2",r"\quad fixed 1\,MB"), row("shed","2",r"\quad + shed"),
                 row("autotune","2",r"\quad \sys"), r"\midrule",
                 r"\multicolumn{%d}{@{}l}{\emph{it does not; the stack re-segments}} \\" % (len(rates)+1),
                 row("base_noshed","0",r"\quad fixed 1\,MB"), row("shed","0",r"\quad + shed"),
                 row("autotune","0",r"\quad \sys"),
                 r"\bottomrule", r"\end{tabular}",
                 r"\caption{Goodput with moderation %s. Re-segmentation raises the" % dim,
                 r"per-packet cost and lowers the ceiling, which changes which lever pays.}",
                 r"\label{tab:grolevers%s}" % dim, r"\end{table}", ""]
    emit("grolevers", "\n".join(outs) + "\n" if outs else r"\emph{(pending)}" + "\n")

# ------------------------------------------------------------ multicore
def t_multicore():
    d = newest("~/lab/logs/mc*_*")
    if not d: return print("multicore: no data")
    agg = {}
    for lbl, arfs, tot, busy in load(d, 4):
        agg.setdefault((lbl, arfs), []).append(float(tot))
    names = [("static", r"fixed 1\,MB"), ("nobudget", r"sizing, no allowance"),
             ("budget", r"\sys")]
    rows = []
    for k, lab in names:
        a0 = agg.get((k,"0"), []); a1 = agg.get((k,"1"), [])
        if not a0 and not a1: continue
        f0 = f"{mean(a0):.1f}" if a0 else "--"
        f1 = f"{mean(a1):.1f}" if a1 else "--"
        rows.append(f"{lab} & {f0} & {f1}" + r" \\")
    out = [r"\begin{table}[t]", r"\centering", r"\small",
           r"\begin{tabular}{@{}lrr@{}}", r"\toprule",
           r"configuration & RSS only & with aRFS \\", r"\midrule", *rows,
           r"\bottomrule", r"\end{tabular}",
           r"\caption{Four receive queues, four cores, eight sockets. The",
           r"descriptor footprint is four times a single queue's, so the",
           r"allowance has less room to distribute; steering flows to the core",
           r"running their consumer restores the cache hand-off.}",
           r"\label{tab:multicore}", r"\end{table}"]
    emit("multicore", "\n".join(out) + "\n")

# ------------------------------------------------------------ main table
def t_workloads():
    d = newest("~/lab/logs/twowl_*")
    if not d: return print("workloads: no data")
    agg = {}
    for r in load(d, 7):
        dim, buf, wl, got, busy, jain, loss = r[:7]
        agg.setdefault((dim, buf, wl), []).append((float(got), float(loss)))
    order = [("s1M", r"fixed 1\,MB"), ("s1M_shed", r"fixed 1\,MB + shed"),
             ("s8M", r"fixed 8\,MB"), ("s8M_shed", r"fixed 8\,MB + shed"),
             ("auto", r"\sys"), ("auto_shed", r"\sys + shed")]
    def panel(dim):
        out = []
        for k, lab in order:
            cells, ok = [], False
            for wl in ("W1", "W2"):
                v = agg.get((dim, k, wl), [])
                if v:
                    ok = True
                    cells += [f"{mean([x[0] for x in v]):.1f}", f"{mean([x[1] for x in v]):.1f}"]
                else:
                    cells += ["--", "--"]
            if ok: out.append(f"{lab} & " + " & ".join(cells) + r" \\")
        return out
    n = max((len(v) for v in agg.values()), default=0)
    out = [r"\begin{table}[t]", r"\centering", r"\small",
           r"\begin{tabular}{@{}lrrrr@{}}", r"\toprule",
           r"& \multicolumn{2}{c}{W1: one socket} & \multicolumn{2}{c}{W2: eight sockets} \\",
           r"\cmidrule(lr){2-3}\cmidrule(lr){4-5}",
           r"configuration & Gb/s & loss & Gb/s & loss \\", r"\midrule",
           r"\multicolumn{5}{@{}l}{\emph{moderation on, the driver default}} \\"]
    out += ["\\quad " + r for r in panel("on")]
    out += [r"\midrule", r"\multicolumn{5}{@{}l}{\emph{moderation off}} \\"]
    out += ["\\quad " + r for r in panel("off")]
    out += [r"\bottomrule", r"\end{tabular}",
           r"\caption{Both workloads on one kernel and one setting, $n=%d$." % n,
           r"Loss is what the sender offered and the receiver did not deliver;",
           r"goodput alone does not distinguish carrying a load from discarding",
           r"much of it. Each fixed buffer loses one workload badly. A small one",
           r"with driver-side discard carries both under either moderation",
           r"setting; a large one with the same discard still does not.}",
           r"\label{tab:nostatic}", r"\end{table}"]
    emit("workloads", "\n".join(out) + "\n")

# t_multicore is not generated: on this hardware the link binds before the
# receive path does at four queues, so every arm returns the offered rate.
for f in (t_shedmarg, t_protiso, t_grolevers, t_workloads):
    try: f()
    except Exception as e: print(f"{f.__name__}: {e}")
