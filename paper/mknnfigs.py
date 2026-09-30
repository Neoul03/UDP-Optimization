#!/usr/bin/env python3
"""다수 sender → 소켓 1 개 (fanin) 와 n:n 을 나란히. MTU 1500/9000 × 처리량/지연.

두 모드가 다른 것은 **수신 소켓 수 하나**다. sender 쪽은 완전히 동일하다.
TCP 는 연결마다 소켓이 생기므로 fanin 을 할 수 없다 — TCP 선은 두 모드에서 같은
실험이고, 그것 자체가 논지다 (다수 sender → 소켓 하나는 UDP 에만 있는 경우).

.dat 을 .pdf 옆에 남긴다 - 실험 재실행 없이 수치를 확인할 수 있어야 한다.
"""
import os, glob, subprocess, sys, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = f"{HERE}/figs"; os.makedirs(OUT, exist_ok=True)

d = sorted(glob.glob(os.path.expanduser("~/lab/logs/nn_*")), reverse=True)
d = [x for x in d if os.path.exists(f"{x}/raw.txt") and os.path.getsize(f"{x}/raw.txt") > 0]
if not d:
    sys.exit("no nn data")
SRC = d[0]

# raw: mode mtu nsend cfg goodput p50 p99 probe_loss
rows = collections.defaultdict(list)
for ln in open(f"{SRC}/raw.txt"):
    f = ln.split()
    if len(f) < 8: continue
    rows[(f[0], int(f[1]), int(f[2]), f[3])].append(tuple(float(x) for x in f[4:8]))

def m(k, i):
    v = rows.get(k)
    return statistics.mean(x[i] for x in v) if v else None

COUNTS = sorted({k[2] for k in rows})
CFGS = [("udp_plain",   "original UDP (setsockopt off)", 2),
        ("udp_sockopt", "original UDP (setsockopt on)",  3),
        ("tcp",         "original TCP",                  4),
        ("udp_ours",    "ours",                          1)]
MODES = [("fanin", "N senders to ONE receiving socket"),
         ("nn",    "N senders to N receiving sockets (n:n)")]

COMMON = """set terminal pdfcairo font "Helvetica,10" size %s
set output "%s"
set style line 1 lc rgb '#1b4965' lw 2.5 pt 7 ps 0.7
set style line 2 lc rgb '#c1666b' lw 2.0 pt 5 ps 0.6 dt 2
set style line 3 lc rgb '#c1666b' lw 2.0 pt 4 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2.5 pt 9 ps 0.8
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set key noenhanced
set xtics nomirror
set ytics nomirror
set logscale x 2
set xrange [0.85:19]
set xtics (%s)
""" % ("%s", "%s", ",".join(map(str, COUNTS)))

def emit(name, dat, gp):
    open(f"{OUT}/{name}.dat", "w").write(dat)
    open(f"{OUT}/{name}.gp", "w").write(gp)
    r = subprocess.run(["gnuplot", f"{OUT}/{name}.gp"], capture_output=True, text=True)
    print(f"{name}: {'ok' if r.returncode == 0 else r.stderr.strip()[:200]}")

def table(mode, mtu, cols):
    dat = "# nsend  " + "  ".join(f"{c[0]}_{h}" for c in CFGS for h, _ in cols) + "\n"
    for n in COUNTS:
        cells = []
        for k, _, _ in CFGS:
            for _, i in cols:
                v = m((mode, mtu, n, k), i)
                cells.append(f"{v:.2f}" if v is not None else "NaN")
        dat += f"{n}  " + "  ".join(cells) + "\n"
    return dat

def tput_plot(base):
    return ", \\\n     ".join(
        [f'"{OUT}/{base}.dat" u 1:2 w lp ls {CFGS[0][2]} t "{CFGS[0][1]}"'] +
        [f'"" u 1:{i+2} w lp ls {c[2]} t "{c[1]}"' for i, c in enumerate(CFGS[1:], 1)])

for mode, mlabel in MODES:
    for mtu in (1500, 9000):
        if not any(k[0] == mode and k[1] == mtu for k in rows): continue

        base = f"nn_tput_{mode}_m{mtu}"
        emit(base, table(mode, mtu, [("got", 0)]),
             COMMON % ("3.4in,2.3in", f"{OUT}/{base}.pdf") + f'''
set title "MTU {mtu} - {mlabel}" font ",9"
set xlabel "number of senders"
set ylabel "goodput (Gbit/s)"
set yrange [0:60]
set key bottom right reverse Left samplen 1.5 font ",8"
plot {tput_plot(base)}
''')

        # 지연은 p50/p99 를 따로. 한 장에 넣으면 8 선이라 안 읽힌다.
        for col, pct in ((1, "p50"), (2, "p99")):
            base = f"nn_{pct}_{mode}_m{mtu}"
            emit(base, table(mode, mtu, [(pct, col)]),
                 COMMON % ("3.4in,2.3in", f"{OUT}/{base}.pdf") + f'''
set title "MTU {mtu} ({pct}) - {mlabel}" font ",9"
set xlabel "number of senders"
set ylabel "probe round trip (us)"
set logscale y
set key top left reverse Left samplen 1.5 font ",8"
plot {tput_plot(base)}
''')

        # 프로브 손실. 지연 그래프는 이것 없이 읽으면 안 된다 (생존 편향).
        base = f"nn_loss_{mode}_m{mtu}"
        emit(base, table(mode, mtu, [("loss", 3)]),
             COMMON % ("3.4in,2.3in", f"{OUT}/{base}.pdf") + f'''
set title "MTU {mtu} (probe loss) - {mlabel}" font ",9"
set xlabel "number of senders"
set ylabel "probe packets lost (%)"
set yrange [0:60]
set key top left reverse Left samplen 1.5 font ",8"
plot {tput_plot(base)}
''')

print(f"source: {SRC}")
