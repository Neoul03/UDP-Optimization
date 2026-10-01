#!/usr/bin/env python3
"""같은 사다리를 두 도구로 잰 것을 겹쳐 그린다.

  udp_blast/udp_sink  byte-budget 스핀 페이싱. 밀림 없음. 수신측이 가볍다
  iperf3              clock_nanosleep 페이싱. 밀림 → 버스트. 수신측이 datagram
                      마다 시퀀스/jitter/손실 판정을 한다

TCP arm 은 두 조에서 **같은 도구(iperf3)** 다. 그래서 TCP 선이 겹치는지가
런 사이 재현성의 대조군이 된다 - 겹치면 차이는 UDP 쪽 도구 탓이다.

결론이 도구에 의존하는지가 이 그림의 질문이다.
"""
import os, glob, subprocess, sys, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = f"{HERE}/figs"; os.makedirs(OUT, exist_ok=True)


def load(pattern, cols):
    d = sorted(glob.glob(os.path.expanduser(pattern)), key=os.path.getmtime, reverse=True)
    d = [x for x in d if os.path.exists(f"{x}/raw.txt") and os.path.getsize(f"{x}/raw.txt") > 0]
    if not d:
        sys.exit(f"no data for {pattern}")
    rows = collections.defaultdict(list)
    for ln in open(f"{d[0]}/raw.txt"):
        f = ln.split()
        if len(f) < cols: continue
        rows[(int(f[0]), f[1])].append(float(f[2]))
    return rows, d[0]


# 두 사다리. arm 이름이 다르다 (udp_sockopt vs udp).
blast, blast_src = load("~/lab/logs/ladder_2*", 5)
ipf, ipf_src = load("~/lab/logs/ladderip_*", 6)
blast = {(r, ('udp' if c == 'udp_sockopt' else ('ours' if c == 'udp_ours' else c))): v
         for (r, c), v in blast.items()}

RATES = sorted({k[0] for k in ipf} & {k[0] for k in blast})
ARMS = [("udp", "original UDP"), ("tcp", "original TCP"), ("ours", "ours")]


def mean(rows, k):
    v = rows.get(k)
    return statistics.mean(v) if v else None


dat = "# rate  " + "  ".join(f"{a}_blast {a}_iperf" for a, _ in ARMS) + "\n"
for r in RATES:
    cells = []
    for a, _ in ARMS:
        for src in (blast, ipf):
            v = mean(src, (r, a))
            cells.append(f"{v:.2f}" if v is not None else "NaN")
    dat += f"{r}  " + "  ".join(cells) + "\n"

# 도구마다 선 스타일을 바꾸고 arm 마다 색을 맞춘다: 실선 = udp_blast, 점선 = iperf3
STYLE = {"udp": 2, "tcp": 4, "ours": 1}
parts = []
for i, (a, lab) in enumerate(ARMS):
    src = f'"{OUT}/toolcmp.dat"' if i == 0 else '""'
    parts.append(f'{src} u 1:{2 + 2 * i} w lp ls {STYLE[a]} t "{lab} - udp_blast"')
    parts.append(f'"" u 1:{3 + 2 * i} w lp ls {STYLE[a]} dt 3 pt 6 t "{lab} - iperf3"')
plot = ", \\\n     ".join([r"x w l lc rgb '#b0b0b0' dt 3 lw 1.2 t 'lossless (y = x)'"] + parts)

gp = f'''set terminal pdfcairo noenhanced font "Helvetica,10" size 5.2in,3.4in
set output "{OUT}/toolcmp.pdf"
set style line 1 lc rgb '#1b4965' lw 2.5 pt 7 ps 0.6
set style line 2 lc rgb '#c1666b' lw 2.5 pt 5 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2.5 pt 9 ps 0.7
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set key noenhanced
set xtics nomirror 10
set ytics nomirror 10
set title "MTU 9000, single flow: does the benchmark tool change the answer?" font ",11"
set xlabel "rate the sender was asked for (Gbit/s)"
set ylabel "delivered goodput (Gbit/s)"
set xrange [0:85]
set yrange [0:85]
set key top left reverse Left samplen 1.5 font ",8" maxrows 4
plot {plot}
'''
open(f"{OUT}/toolcmp.dat", "w").write(dat)
open(f"{OUT}/toolcmp.gp", "w").write(gp)
r = subprocess.run(["gnuplot", f"{OUT}/toolcmp.gp"], capture_output=True, text=True)
print("toolcmp:", "ok" if r.returncode == 0 else r.stderr.strip()[:300])

print(f"\n{'rate':>5} " + " ".join(f"{a + '_' + t:>14}" for a, _ in ARMS for t in ("blast", "iperf")))
for r_ in RATES:
    cells = []
    for a, _ in ARMS:
        for src in (blast, ipf):
            v = mean(src, (r_, a))
            cells.append(f"{v:>14.2f}" if v is not None else f"{'-':>14}")
    print(f"{r_:>5} " + " ".join(cells))

print("\n무손실 천장 (배달 >= 0.99 x 요청인 마지막 점) / 최고:")
for a, lab in ARMS:
    for src, tname in ((blast, "udp_blast"), (ipf, "iperf3")):
        vals = [(r_, mean(src, (r_, a))) for r_ in RATES]
        vals = [(r_, v) for r_, v in vals if v is not None]
        if not vals: continue
        ll = [r_ for r_, v in vals if v >= 0.99 * r_]
        pk_r, pk_v = max(vals, key=lambda t: t[1])
        print(f"  {lab:14s} {tname:10s} 무손실 {max(ll) if ll else 0:>3} G   최고 {pk_v:5.2f} @ {pk_r} G")

print("\nours / tcp 비 (도구별):")
for r_ in RATES:
    out = []
    for src, tname in ((blast, "blast"), (ipf, "iperf")):
        o, t = mean(src, (r_, "ours")), mean(src, (r_, "tcp"))
        out.append(f"{tname} x{o / t:.2f}" if o and t else f"{tname} -")
    print(f"  {r_:>3} G   " + "   ".join(out))
print(f"\nsource: {blast_src}\n        {ipf_src}")
