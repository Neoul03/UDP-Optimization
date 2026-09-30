#!/usr/bin/env python3
"""처리량과 지연을 같은 실행에서 잰 격자(grid2)로 그래프 6 장.

  축 A  MTU 1500..9000, flow 1 고정          -> 처리량 / 지연
  축 B  flow 1..16, MTU 1500 고정            -> 처리량 / 지연
  축 B  flow 1..16, MTU 9000 고정            -> 처리량 / 지연

"기존 UDP" 를 한 줄로 그리면 안 된다. 앱이 setsockopt(SO_RCVBUF) 를 부르느냐에
따라 기준선이 갈리고 둘 다 현실에 존재한다 (부르면 64MB 를 요청해도 rmem_max
기본값에 막혀 416KB 다). 그래서 네 줄을 그린다.

지연은 네 조건 모두에 동일한 저속 프로브를 흘려 잰 것이라 프로토콜이 달라도 같은
자로 비교된다. p50 은 실선, p99 는 같은 색 점선. y 는 로그축 — TCP 가 ms 대까지
간다.

.dat 을 .pdf 옆에 남긴다 - 실험 재실행 없이 수치를 확인할 수 있어야 한다.
"""
import os, glob, subprocess, sys, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = f"{HERE}/figs"; os.makedirs(OUT, exist_ok=True)

d = sorted(glob.glob(os.path.expanduser("~/lab/logs/grid2_*")), reverse=True)
d = [x for x in d if os.path.exists(f"{x}/raw.txt") and os.path.getsize(f"{x}/raw.txt") > 0]
if not d:
    sys.exit("no grid2 data")
SRC = d[0]

# raw: mtu nflow cfg goodput p50 p99 probe_loss
rows = collections.defaultdict(list)
for ln in open(f"{SRC}/raw.txt"):
    f = ln.split()
    if len(f) < 7: continue
    rows[(int(f[0]), int(f[1]), f[2])].append(tuple(float(x) for x in f[3:7]))

def m(k, i):
    v = rows.get(k)
    return statistics.mean(x[i] for x in v) if v else None

MTUS  = sorted({k[0] for k in rows})
FLOWS = sorted({k[1] for k in rows if k[0] == 9000}) or sorted({k[1] for k in rows})
# (키, 범례, gnuplot linestyle)
CFGS = [("udp_plain",   "original UDP (setsockopt off)", 2),
        ("udp_sockopt", "original UDP (setsockopt on)",  3),
        ("tcp",         "original TCP",                  4),
        ("udp_ours",    "ours",                          1)]

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
"""

def emit(name, dat, gp):
    open(f"{OUT}/{name}.dat", "w").write(dat)
    open(f"{OUT}/{name}.gp", "w").write(gp)
    r = subprocess.run(["gnuplot", f"{OUT}/{name}.gp"], capture_output=True, text=True)
    print(f"{name}: {'ok' if r.returncode == 0 else r.stderr.strip()[:200]}")

def table(xs, key_of, cols):
    """cols = [(헤더, raw 열 인덱스)] — 설정마다 그 열들을 차례로 낸다."""
    dat = "# x  " + "  ".join(f"{c[0]}_{h}" for c in CFGS for h, _ in cols) + "\n"
    for x in xs:
        cells = []
        for k, _, _ in CFGS:
            for _, i in cols:
                v = m(key_of(x, k), i)
                cells.append(f"{v:.2f}" if v is not None else "NaN")
        dat += f"{x}  " + "  ".join(cells) + "\n"
    return dat

def tput_plot(base):
    return ", \\\n     ".join(
        [f'"{OUT}/{base}.dat" u 1:2 w lp ls {CFGS[0][2]} t "{CFGS[0][1]}"'] +
        [f'"" u 1:{i+2} w lp ls {c[2]} t "{c[1]}"' for i, c in enumerate(CFGS[1:], 1)])

AXES = [
    # (파일 접미사, 제목 꼬리, x 값들, x 라벨, key_of, x 설정)
    ("f1",    "1 flow",      MTUS,  "MTU (bytes)",
     lambda x, k: (x, 1, k),
     "set xtics 1500\nset xrange [1000:9500]"),
    ("m1500", "MTU 1500",    FLOWS, "concurrent UDP flows (sockets)",
     lambda x, k: (1500, x, k),
     "set logscale x 2\nset xrange [0.85:19]\nset xtics (" + ",".join(map(str, FLOWS)) + ")"),
    ("m9000", "MTU 9000",    FLOWS, "concurrent UDP flows (sockets)",
     lambda x, k: (9000, x, k),
     "set logscale x 2\nset xrange [0.85:19]\nset xtics (" + ",".join(map(str, FLOWS)) + ")"),
]

for suffix, title, xs, xlab, key_of, xcfg in AXES:
    # ── 처리량 ──
    base = f"g2_tput_{suffix}"
    emit(base, table(xs, key_of, [("got", 0)]),
         COMMON % ("3.4in,2.3in", f"{OUT}/{base}.pdf") + f'''
set title "{title}: throughput" font ",11"
set xlabel "{xlab}"
set ylabel "goodput (Gbit/s)"
set yrange [0:60]
{xcfg}
set key bottom right reverse Left samplen 1.5 font ",8"
plot {tput_plot(base)}
''')

    # ── 프로브 손실 ──
    # 지연 그래프를 이것 없이 보면 안 된다. p50/p99 는 **배달된 것만** 세므로,
    # 손실이 30% 인 설정의 p99 와 0.02% 인 설정의 p99 는 같은 자가 아니다
    # (생존 편향). 폐기는 지연 민감 흐름을 가리지 않는다.
    base = f"g2_loss_{suffix}"
    emit(base, table(xs, key_of, [("loss", 3)]),
         COMMON % ("3.4in,2.3in", f"{OUT}/{base}.pdf") + f'''
set title "{title}: probe-flow loss" font ",11"
set xlabel "{xlab}"
set ylabel "probe packets lost (%)"
set yrange [0:40]
{xcfg}
set key top left reverse Left samplen 1.5 font ",8"
plot {tput_plot(base)}
''')

    # ── 지연. p50 과 p99 를 **따로** 그린다 ──
    # 한 장에 넣으면 4 설정 x 2 분위 = 8 선이라 읽을 수가 없다.
    for col, pct in ((1, "p50"), (2, "p99")):
        base = f"g2_{pct}_{suffix}"
        emit(base, table(xs, key_of, [(pct, col)]),
             COMMON % ("3.4in,2.3in", f"{OUT}/{base}.pdf") + f'''
set title "{title}: probe round trip ({pct})" font ",11"
set xlabel "{xlab}"
set ylabel "round trip (us)"
set logscale y
{xcfg}
set key top left reverse Left samplen 1.5 font ",8"
plot {tput_plot(base)}
''')

print(f"source: {SRC}")
