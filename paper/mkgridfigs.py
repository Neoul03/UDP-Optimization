#!/usr/bin/env python3
"""랩미팅용 격자 그래프: MTU x flow 수 를 네 설정으로 비교.

"기존 UDP" 를 한 줄로 그리면 안 된다. 앱이 setsockopt(SO_RCVBUF) 를 부르느냐에
따라 기준선이 갈리고, 둘 다 현실에 존재한다:
  udp_plain    안 부름          -> 208KB
  udp_sockopt  64MB 요청        -> rmem_max 기본값에 막혀 416KB (요청의 0.6%)
그래서 네 줄을 그린다. 우리 것의 이득을 부풀리지 않으려면 둘 다 보여야 한다.

.dat 을 .pdf 옆에 남긴다 - 실험 재실행 없이 수치를 확인할 수 있어야 한다.
"""
import os, glob, subprocess, sys, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = f"{HERE}/figs"; os.makedirs(OUT, exist_ok=True)

d = sorted(glob.glob(os.path.expanduser("~/lab/logs/grid_*")), reverse=True)
d = [x for x in d if os.path.exists(f"{x}/raw.txt") and os.path.getsize(f"{x}/raw.txt") > 0]
if not d:
    sys.exit("no grid data")
SRC = d[0]

rows = collections.defaultdict(list)   # (mtu, nflow, cfg) -> [goodput]
for ln in open(f"{SRC}/raw.txt"):
    f = ln.split()
    if len(f) < 4: continue
    rows[(int(f[0]), int(f[1]), f[2])].append(float(f[3]))

def m(k):
    v = rows.get(k)
    return statistics.mean(v) if v else None

MTUS  = sorted({k[0] for k in rows})
FLOWS = sorted({k[1] for k in rows})
# (키, 범례, gnuplot linestyle)
CFGS = [("udp_plain",   "stock UDP (no setsockopt)", 2),
        ("udp_sockopt", "stock UDP (SO_RCVBUF 64MB)", 3),
        ("tcp",         "stock TCP",                  4),
        ("udp_ours",    "ours",                       1)]

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
set yrange [0:60]
"""

def emit(name, dat, gp):
    open(f"{OUT}/{name}.dat", "w").write(dat)
    open(f"{OUT}/{name}.gp", "w").write(gp)
    r = subprocess.run(["gnuplot", f"{OUT}/{name}.gp"], capture_output=True, text=True)
    print(f"{name}: {'ok' if r.returncode == 0 else r.stderr.strip()[:200]}")

def table(xs, cell):
    dat = "# x  " + "  ".join(c[0] for c in CFGS) + "\n"
    for x in xs:
        cells = [(f"{v:.2f}" if (v := cell(x, k)) is not None else "NaN") for k, _, _ in CFGS]
        dat += f"{x}  " + "  ".join(cells) + "\n"
    return dat

def plotcmd(base):
    return ", \\\n     ".join(
        [f'"{OUT}/{base}.dat" u 1:2 w lp ls {CFGS[0][2]} t "{CFGS[0][1]}"'] +
        [f'"" u 1:{i+2} w lp ls {c[2]} t "{c[1]}"' for i, c in enumerate(CFGS[1:], 1)])

# ── x축 = MTU, flow 수 고정 ──
for nf in FLOWS:
    base = f"grid_tput_f{nf}"
    dat = table(MTUS, lambda x, k, nf=nf: m((x, nf, k)))
    gp = COMMON % ("3.4in,2.3in", f"{OUT}/{base}.pdf") + f'''
set title "{nf} concurrent flow(s)" font ",11"
set xlabel "MTU (bytes)"
set ylabel "goodput (Gbit/s)"
set xtics 1500
set xrange [1000:9500]
set key bottom right reverse Left samplen 1.5 font ",8"
plot {plotcmd(base)}
'''
    emit(base, dat, gp)

# ── x축 = flow 수, MTU 고정 ──
for mtu in MTUS:
    base = f"grid_tput_m{mtu}"
    dat = table(FLOWS, lambda x, k, mtu=mtu: m((mtu, x, k)))
    gp = COMMON % ("3.4in,2.3in", f"{OUT}/{base}.pdf") + f'''
set title "MTU {mtu}" font ",11"
set xlabel "concurrent UDP flows (sockets)"
set ylabel "goodput (Gbit/s)"
set logscale x 2
set xrange [0.85:19]
set xtics ({",".join(str(f) for f in FLOWS)})
set key bottom right reverse Left samplen 1.5 font ",8"
plot {plotcmd(base)}
'''
    emit(base, dat, gp)

# ── 한 장 요약: flow 수 평균을 MTU 축에 ──
base = "grid_tput_summary"
def avg_over_flows(x, k):
    v = [m((x, nf, k)) for nf in FLOWS]
    v = [z for z in v if z is not None]
    return statistics.mean(v) if v else None
dat = table(MTUS, avg_over_flows)
gp = COMMON % ("4.6in,2.8in", f"{OUT}/{base}.pdf") + f'''
set title "throughput vs MTU (mean over 1/2/4/8/16 flows)" font ",11"
set xlabel "MTU (bytes)"
set ylabel "goodput (Gbit/s)"
set xtics 1500
set xrange [1000:9500]
set key bottom right reverse Left samplen 1.5
plot {plotcmd(base)}
'''
emit(base, dat, gp)

print(f"source: {SRC}")
