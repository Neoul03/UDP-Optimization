#!/usr/bin/env python3
"""제공률 65 Gb/s 고정, MTU 1500..9000 을 x 축에. 사다리 그림과 짝이다.

arm 세 개. 앱은 **항상 setsockopt(SO_RCVBUF) 를 부른다**고 가정하므로 범례에
따로 적지 않는다 - 기존 커널에서는 그 요청이 rmem_max 기본값에 막혀 416KB 가
되는 것이고, 그게 기존 UDP 의 현실이다.

요청선(65 G)을 가로 점선으로 긋는다. 거기 붙어 있으면 무손실이다.
"""
import os, glob, subprocess, sys, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = f"{HERE}/figs"; os.makedirs(OUT, exist_ok=True)

PAT = sys.argv[1] if len(sys.argv) > 1 else "~/lab/logs/mtu65_*"
TAG = sys.argv[2] if len(sys.argv) > 2 else "mtu65"
d = sorted(glob.glob(os.path.expanduser(PAT)), key=os.path.getmtime, reverse=True)
d = [x for x in d if os.path.exists(f"{x}/raw.txt") and os.path.getsize(f"{x}/raw.txt") > 0]
if not d:
    sys.exit("no mtu65 data")
SRC = d[0]

# raw: mtu cfg goodput tx busy
rows = collections.defaultdict(list)
for ln in open(f"{SRC}/raw.txt"):
    f = ln.split()
    if len(f) < 5: continue
    rows[(int(f[0]), f[1])].append((float(f[2]), float(f[3]), float(f[4])))

MTUS = sorted({k[0] for k in rows})
# 주 그래프는 세 개. ours_lock(앱이 SO_RCVBUF 를 부른 경우)은 아래 표에만 낸다.
CFGS = [("udp",  "original UDP",  2),
        ("tcp",  "original TCP",  4),
        ("ours", "ours",          1)]
DIAG = ("ours_lock", "ours (app set SO_RCVBUF)")
REQ = 65

def stat(k, i):
    v = rows.get(k)
    if not v: return None, 0.0
    xs = [x[i] for x in v]
    return statistics.mean(xs), (statistics.stdev(xs) if len(xs) > 1 else 0.0)

dat = "# mtu  " + "  ".join(f"{c[0]}_mean {c[0]}_sd" for c in CFGS) + "\n"
for m in MTUS:
    cells = []
    for k, _, _ in CFGS:
        mu, sd = stat((m, k), 0)
        cells += [f"{mu:.2f}", f"{sd:.2f}"] if mu is not None else ["NaN", "NaN"]
    dat += f"{m}  " + "  ".join(cells) + "\n"

plot = ", \\\n     ".join(
    (f'"{OUT}/{TAG}_tput.dat"' if i == 0 else '""') +
    f' u 1:{2 + 2 * i}:{3 + 2 * i} w yerrorlines ls {ls} t "{lab}"'
    for i, (k, lab, ls) in enumerate(CFGS))

gp = f'''set terminal pdfcairo noenhanced font "Helvetica,10" size 4.8in,3.0in
set output "{OUT}/{TAG}_tput.pdf"
set style line 1 lc rgb '#1b4965' lw 2.5 pt 7 ps 0.6
set style line 2 lc rgb '#c1666b' lw 2.5 pt 5 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2.5 pt 9 ps 0.7
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set key noenhanced
set xtics nomirror 1500
set ytics nomirror 10
set title "single flow, one core, sender asked for {REQ} Gbit/s" font ",11"
set xlabel "MTU (bytes)"
set ylabel "delivered goodput (Gbit/s)"
set xrange [1000:9500]
set yrange [0:70]
set arrow from 1000,{REQ} to 9500,{REQ} nohead lc rgb '#b0b0b0' dt 3 lw 1.5
set label "asked for {REQ} G" at 9350,{REQ - 3} right font ",8" tc rgb '#555555'
set key bottom right reverse Left samplen 1.5 font ",9"
plot {plot}
'''

open(f"{OUT}/{TAG}_tput.dat", "w").write(dat)
open(f"{OUT}/{TAG}_tput.gp", "w").write(gp)
r = subprocess.run(["gnuplot", f"{OUT}/{TAG}_tput.gp"], capture_output=True, text=True)
print(f"{TAG}_tput:", "ok" if r.returncode == 0 else r.stderr.strip()[:300])

hdr = [lab for _k, lab, _ in CFGS] + [DIAG[1]]
print(f"\n{'MTU':>6} " + " ".join(f"{h:>24}" if len(h) > 14 else f"{h:>14}" for h in hdr)
      + "   ours/udp  ours/tcp")
for m in MTUS:
    vals = [stat((m, k), 0)[0] for k, _, _ in CFGS]
    dv = stat((m, DIAG[0]), 0)[0]
    row = f"{m:>6} " + " ".join(f"{v:>14.2f}" if v is not None else f"{'-':>14}" for v in vals)
    row += f"{dv:>25.2f}" if dv is not None else f"{'-':>25}"
    u, t, o = vals
    if u and t and o:
        row += f"   x{o/u:5.2f}    x{o/t:5.2f}"
    print(row)

# SO_RCVBUF 상호작용 비용: 같은 커널인데 앱이 부르면 sizing 이 죽는다.
print("\nSO_RCVBUF 를 부르면 잃는 양 (ours -> ours_lock):")
for m in MTUS:
    a = stat((m, "ours"), 0)[0]
    b = stat((m, DIAG[0]), 0)[0]
    if a and b:
        print(f"  MTU {m:<5} {a:6.2f} -> {b:6.2f}   ({(b/a - 1) * 100:+.1f}%)")
print(f"source: {SRC}")
