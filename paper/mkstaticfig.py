#!/usr/bin/env python3
"""정적 sk_rcvbuf 스윕: x = 버퍼 크기, y = 처리량. 제공률 세 점을 한 장에.

논문의 핵심 한 장. **양쪽 절벽**이 보여야 한다:
  왼쪽  버퍼 < NAPI 배치  -> 담을 데가 없어 폐기            (P1)
  오른쪽 ring + sk_rcvbuf > L3 -> copyout 이 DRAM 히트       (P3)
그리고 골의 위치가 제공률에 따라 움직이면, 어떤 정적 값도 조건 무관하게 맞을 수
없다는 뜻이다 — 그게 sizing 이 필요한 이유다.

세로 보조선 두 개를 긋는다:
  1.15 MB  DIM 이 정착하는 rx-frames 128 x 8972B = NAPI poll 한 번의 버스트
  16 MB    L3 18MB - ring 2MB. 이 너머는 ring 과 합쳐 캐시를 넘는다
"""
import os, glob, subprocess, sys, statistics, collections

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = f"{HERE}/figs"; os.makedirs(OUT, exist_ok=True)

d = sorted(glob.glob(os.path.expanduser("~/lab/logs/staticbuf_*")), key=os.path.getmtime, reverse=True)
d = [x for x in d if os.path.exists(f"{x}/raw.txt") and os.path.getsize(f"{x}/raw.txt") > 0]
if not d:
    sys.exit("no staticbuf data")
SRC = d[0]

# raw: size rate goodput tx busy rb
rows = collections.defaultdict(list)
for ln in open(f"{SRC}/raw.txt"):
    f = ln.split()
    if len(f) < 5: continue
    rows[(int(f[1]), int(f[0]))].append((float(f[2]), float(f[3]), float(f[4])))

RATES = sorted({k[0] for k in rows})
SIZES = sorted({k[1] for k in rows})
MB = 1048576.0

def stat(k, i):
    v = rows.get(k)
    if not v: return None, None
    xs = [x[i] for x in v]
    return statistics.mean(xs), (statistics.stdev(xs) if len(xs) > 1 else 0.0)

# 제공률마다 선 하나. sd 를 errorbar 로 같이 낸다 - N=1 비교 금지 규칙의 시각화.
dat = "# size_MB  " + "  ".join(f"r{r}_mean r{r}_sd" for r in RATES) + "\n"
for sz in SIZES:
    cells = []
    for r in RATES:
        mu, sd = stat((r, sz), 0)
        cells += [f"{mu:.2f}", f"{sd:.2f}"] if mu is not None else ["NaN", "NaN"]
    dat += f"{sz / MB:.4f}  " + "  ".join(cells) + "\n"

STYLES = [1, 4, 2, 3]
plot = ", \\\n     ".join(
    (f'"{OUT}/static_tput.dat"' if i == 0 else '""') +
    f' u 1:{2 + 2 * i}:{3 + 2 * i} w yerrorlines ls {STYLES[i % len(STYLES)]}'
    f' t "offered {r} Gb/s"'
    for i, r in enumerate(RATES))

gp = f'''set terminal pdfcairo noenhanced font "Helvetica,10" size 4.8in,3.0in
set output "{OUT}/static_tput.pdf"
set style line 1 lc rgb '#1b4965' lw 2.5 pt 7 ps 0.6
set style line 2 lc rgb '#c1666b' lw 2.5 pt 5 ps 0.6
set style line 3 lc rgb '#5b8c5a' lw 2.5 pt 4 ps 0.6
set style line 4 lc rgb '#8d8741' lw 2.5 pt 9 ps 0.7
set grid ls 0 lc rgb '#d0d0d0'
set border 3
set key noenhanced
set xtics nomirror
set ytics nomirror
set title "MTU 9000, one socket: throughput vs static sk_rcvbuf" font ",11"
set xlabel "static sk_rcvbuf (MiB, log scale)"
set ylabel "goodput (Gbit/s)"
set logscale x 2
set xtics ("208K" 0.203, "512K" 0.5, "1M" 1, "2M" 2, "4M" 4, "8M" 8, "18M" 18)
set yrange [0:60]
set arrow from 1.15,0 to 1.15,60 nohead lc rgb '#888888' dt 2
set label "one NAPI batch\\n= rx-frames 128 x 8972B" at 1.25,9 font ",7" tc rgb '#555555'
set arrow from 16,0 to 16,60 nohead lc rgb '#888888' dt 2
set label "L3 - ring\\n= 18M - 2M" at 15.2,9 right font ",7" tc rgb '#555555'
set key at graph 0.44,0.98 top left reverse Left samplen 1.5 font ",8"
plot {plot}
'''

open(f"{OUT}/static_tput.dat", "w").write(dat)
open(f"{OUT}/static_tput.gp", "w").write(gp)
r = subprocess.run(["gnuplot", f"{OUT}/static_tput.gp"], capture_output=True, text=True)
print("static_tput:", "ok" if r.returncode == 0 else r.stderr.strip()[:300])

# sender 가 실제로 낸 속도. 수신측을 쟀다고 주장하려면 이게 제공률과 같아야 한다.
print("\n실제 sender bitrate (tx, Gb/s):")
for r_ in RATES:
    txs = [stat((r_, sz), 1)[0] for sz in SIZES]
    txs = [t for t in txs if t is not None]
    if txs:
        print(f"  offered {r_}G -> tx {min(txs):.2f} ~ {max(txs):.2f} "
              f"(평균 {statistics.mean(txs):.2f}, 목표비 {statistics.mean(txs)/r_*100:.1f}%)")
print(f"source: {SRC}")
