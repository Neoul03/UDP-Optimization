#!/usr/bin/env python3
"""제공률 사다리: x = sender 가 요청한 속도, y = 배달된 처리량.

세 arm 에 **같은 x 축**을 준다는 것이 요점이다. 지금까지의 격자 캠페인은 UDP 만
과부하에 놓고 TCP 는 혼잡제어로 자기 평형에 앉혀둔 비교였다.

y=x 대각선을 함께 그린다. 그 선 위에 붙어 있으면 무손실이고, 떨어지는 지점이
그 설정의 천장이다. 천장이 어디고 넘은 뒤 어떻게 되는지가 한 장에 보인다.
"""
import os, glob, subprocess, sys, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = f"{HERE}/figs"; os.makedirs(OUT, exist_ok=True)

d = sorted(glob.glob(os.path.expanduser("~/lab/logs/ladder_*")), key=os.path.getmtime, reverse=True)
d = [x for x in d if os.path.exists(f"{x}/raw.txt") and os.path.getsize(f"{x}/raw.txt") > 0]
if not d:
    sys.exit("no ladder data")
SRC = d[0]

# raw: rate cfg goodput tx busy
rows = collections.defaultdict(list)
for ln in open(f"{SRC}/raw.txt"):
    f = ln.split()
    if len(f) < 5: continue
    rows[(int(f[0]), f[1])].append((float(f[2]), float(f[3]), float(f[4])))

RATES = sorted({k[0] for k in rows})
CFGS = [("udp_sockopt", "original UDP", 2),
        ("tcp",         "original TCP",                 4),
        ("udp_ours",    "ours",                         1)]

def stat(k, i):
    v = rows.get(k)
    if not v: return None, 0.0
    xs = [x[i] for x in v]
    return statistics.mean(xs), (statistics.stdev(xs) if len(xs) > 1 else 0.0)

dat = "# offered  " + "  ".join(f"{c[0]}_mean {c[0]}_sd" for c in CFGS) + "\n"
for r in RATES:
    cells = []
    for k, _, _ in CFGS:
        mu, sd = stat((r, k), 0)
        cells += [f"{mu:.2f}", f"{sd:.2f}"] if mu is not None else ["NaN", "NaN"]
    dat += f"{r}  " + "  ".join(cells) + "\n"

plot = ", \\\n     ".join(
    [f'x w l lc rgb \'#b0b0b0\' dt 3 lw 1.5 t "lossless (y = x)"'] +
    [(f'"{OUT}/ladder_tput.dat"' if i == 0 else '""') +
     f' u 1:{2 + 2 * i}:{3 + 2 * i} w yerrorlines ls {ls} t "{lab}"'
     for i, (k, lab, ls) in enumerate(CFGS)])

gp = f'''set terminal pdfcairo noenhanced font "Helvetica,10" size 4.8in,3.1in
set output "{OUT}/ladder_tput.pdf"
set style line 1 lc rgb '#1b4965' lw 2.5 pt 7 ps 0.6
set style line 2 lc rgb '#c1666b' lw 2.5 pt 5 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2.5 pt 9 ps 0.7
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set key noenhanced
set xtics nomirror 10
set ytics nomirror 10
set title "MTU 9000, single flow, one core" font ",11"
set xlabel "rate the sender was asked for (Gbit/s)"
set ylabel "delivered goodput (Gbit/s)"
set xrange [0:85]
set yrange [0:85]
set key top left reverse Left samplen 1.5 font ",9"
plot {plot}
'''

open(f"{OUT}/ladder_tput.dat", "w").write(dat)
open(f"{OUT}/ladder_tput.gp", "w").write(gp)
r = subprocess.run(["gnuplot", f"{OUT}/ladder_tput.gp"], capture_output=True, text=True)
print("ladder_tput:", "ok" if r.returncode == 0 else r.stderr.strip()[:300])

# 무손실 천장 = 배달이 요청의 99% 이상인 마지막 사다리 점.
print("\n무손실 천장 / 최고 처리량:")
for key, lab, _ls in CFGS:
    vals = [(r_, stat((r_, key), 0)[0]) for r_ in RATES]
    vals = [(r_, v) for r_, v in vals if v is not None]
    if not vals:
        continue
    lossless = [r_ for r_, v in vals if v >= 0.99 * r_]
    pk_r, pk_v = max(vals, key=lambda t: t[1])
    print(f"  {lab:30s} 무손실 {max(lossless) if lossless else 0:>3} G   최고 {pk_v:5.2f} @ {pk_r} G")
print(f"source: {SRC}")
