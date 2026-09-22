#!/usr/bin/env python3
"""make_figures.py — 실험 로그를 파싱해 gnuplot 으로 그림을 만든다.

x 축은 "우리가 실제로 조절한 파라미터", y 축은 throughput(Gbps).
각 그림에는 데이터 출처 로그 디렉터리를 캡션으로 박아 추적 가능하게 한다.

출력: ~/lab/figures/*.png  (+ 같은 이름의 .dat, .gp 를 남겨 재생성 가능)

주의: 측정 도구가 다르면 같은 축에 올리지 않는다.
  - iperf3 는 sender pacing 양자화 때문에 천장 아래에서 가짜 손실을 만든다
  - udp_blast(byte-budget pacing) -> udp_sink 가 깨끗한 기준
  두 도구를 비교하는 그림(fig05)만 예외로 나란히 놓는다.
"""
import os, glob, subprocess, statistics, sys

LOGS = os.path.expanduser('~/lab/logs')
OUT  = os.path.expanduser('~/lab/figures')
os.makedirs(OUT, exist_ok=True)

CAPS = {'208K':208,'256K':256,'384K':384,'512K':512,'768K':768,'1M':1024,
        '1M25':1280,'1M5':1536,'2M':2048,'3M':3072,'4M':4096,'6M':6144,
        '8M':8192,'12M':12288,'18M':18432}

def newest(pat):
    d = sorted(glob.glob(os.path.join(LOGS, pat)))
    return d[-1] if d else None

def rows(d, name='raw.txt'):
    p = os.path.join(d, name) if d else None
    if not p or not os.path.exists(p):
        return []
    out = []
    for ln in open(p):
        f = ln.split()
        if f:
            out.append(f)
    return out

def agg(pairs):
    """[(x, y), ...] -> sorted [(x, mean, sd)]"""
    g = {}
    for x, y in pairs:
        g.setdefault(x, []).append(y)
    res = []
    for x in sorted(g):
        v = g[x]
        sd = statistics.stdev(v) if len(v) > 1 else 0.0
        res.append((x, statistics.mean(v), sd))
    return res

def write_dat(path, series):
    """series: {label: [(x, mean, sd)]} -> gnuplot 용 블록 구분 dat"""
    with open(path, 'w') as f:
        for lbl, pts in series.items():
            f.write(f'# {lbl}\n')
            for x, m, sd in pts:
                f.write(f'{x} {m:.3f} {sd:.3f}\n')
            f.write('\n\n')

def plot(name, title, xlabel, dat, series, source,
         logx=False, xtics=None, ylabel='Goodput (Gbit/s)', extra=''):
    gp = os.path.join(OUT, name + '.gp')
    png = os.path.join(OUT, name + '.png')
    datp = os.path.join(OUT, dat)
    plots = []
    for i, lbl in enumerate(series):
        plots.append(f'"{datp}" index {i} using 1:2:3 with yerrorlines '
                     f'lw 2 pt {5+i} ps 1.2 title "{lbl}"')
    with open(gp, 'w') as f:
        f.write(f'''set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "{png}"
set title "{title}" font "Sans,13"
set xlabel "{xlabel}"
set ylabel "{ylabel}"
set grid
set key outside right top
set label "source: {source}" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
{"set logscale x 2" if logx else ""}
{f'set xtics ({xtics})' if xtics else ""}
{extra}
plot {", ".join(plots)}
''')
    subprocess.run(['gnuplot', gp], check=True)
    print('wrote', png)

# ---------------------------------------------------------------- fig01
# rcvbuf x throughput, ring 256 vs 1024, blast (-b 0).  iperf3 기반.
d256, d1024 = newest('rcvbuf_ring256_*'), newest('rcvbuf_ring1024_*')
s = {}
for lbl, d in (('RX ring 256 (4MB desc)', d256), ('RX ring 1024 (16MB desc)', d1024)):
    pts = [(CAPS[r[1]], float(r[4])) for r in rows(d)
           if r[2] == '0' and r[4] != 'NA' and r[1] in CAPS]
    if pts: s[lbl] = agg(pts)
if s:
    write_dat(os.path.join(OUT, 'fig01.dat'), s)
    plot('fig01_rcvbuf_by_ring_blast',
         'Receive buffer vs goodput, by RX ring size (blast, iperf3)',
         'sk_rcvbuf (KiB)', 'fig01.dat', list(s), f'{os.path.basename(d256 or "")}, {os.path.basename(d1024 or "")}',
         logx=True)

# ---------------------------------------------------------------- fig02
# rcvbuf x throughput, ring 128/256/1024 @ 46G, 카운터 실험
s = {}
for lbl, pat in (('RX ring 128', 'cnt_ring128_20260922_1157*'),
                 ('RX ring 256', 'cnt_ring256_*'),
                 ('RX ring 1024', 'cnt_ring1024_*')):
    d = newest(pat)
    pts = [(CAPS[r[1]], float(r[3])) for r in rows(d) if r[3] != 'NA' and r[1] in CAPS]
    if pts: s[lbl] = agg(pts)
if s:
    write_dat(os.path.join(OUT, 'fig02.dat'), s)
    plot('fig02_rcvbuf_by_ring_46g',
         'Receive buffer vs goodput at 46 Gbit/s offered, by RX ring size (iperf3)',
         'sk_rcvbuf (KiB)', 'fig02.dat', list(s), 'cnt_ring{128,256,1024}_*', logx=True)

# ---------------------------------------------------------------- fig03
# offered rate x throughput, ring 128 vs 1024 (iperf3 ladder) + TCP 기준선
s = {}
lad = {'RX ring 1024': ['ladder_ring1024_*'],
       'RX ring 128':  ['ladder_ring128_2*', 'ladder_ring128hi_*',
                        'ladder_ring128crit_*', 'ladder_ring128low_*']}
for lbl, pats in lad.items():
    pts = []
    for p in pats:
        d = newest(p)
        pts += [(int(r[1]), float(r[2])) for r in rows(d)
                if r[0] == 'udp' and r[2] not in ('NA', '0')]
    if pts: s[lbl] = agg(pts)
if s:
    write_dat(os.path.join(OUT, 'fig03.dat'), s)
    plot('fig03_rate_ladder_by_ring',
         'Offered rate vs goodput, by RX ring size (iperf3; TCP shown for reference)',
         'Offered rate (Gbit/s)', 'fig03.dat', list(s), 'ladder_ring*',
         extra='set arrow from graph 0,first 51.4 to graph 1,first 51.4 nohead '
               'lc rgb "#cc0000" dt 2 lw 2\n'
               'set label "TCP 51.4 (default tcp\\_rmem)" at graph 0.02,first 52.6 '
               'tc rgb "#cc0000" font "Sans,9"')

# ---------------------------------------------------------------- fig04  ★ 핵심
# offered rate x throughput, shed on/off.  깨끗한 도구(udp_blast -> udp_sink).
s = {}
pts = {0: [], 1: []}
for p in ('shedclean_20260922_145127', 'shedclean_20260922_145724'):
    d = os.path.join(LOGS, p)
    for r in rows(d):
        pts[int(r[0])].append((int(r[1]), float(r[2])))
for k, lbl in ((0, 'shed off'), (1, 'shed on')):
    if pts[k]: s[lbl] = agg(pts[k])
if s:
    write_dat(os.path.join(OUT, 'fig04.dat'), s)
    plot('fig04_shed_vs_rate',
         'Driver-level shed turns post-ceiling collapse into a plateau (udp_blast to udp_sink)',
         'Offered rate (Gbit/s)', 'fig04.dat', list(s), 'shedclean_20260922_1451/1457',
         extra='set arrow from 48,graph 0 to 48,graph 1 nohead lc rgb "#888888" dt 3\n'
               'set label "CPU ceiling (48G)" at 48.4,graph 0.06 tc rgb "#888888" font "Sans,9"')

# ---------------------------------------------------------------- fig05
# 측정 도구 비교: iperf3 vs 자체 도구
s = {}
d = newest('ladder_ring128smooth_*')
pts = [(int(r[1]), float(r[2])) for r in rows(d) if r[0] == 'udp' and r[2] not in ('NA','0')]
if pts: s['iperf3 (-b, tick pacing)'] = agg(pts)
d = newest('tools_*')
pts = [(int(r[0]), float(r[2])) for r in rows(d)]
if pts: s['udp_blast (byte-budget) to udp_sink'] = agg(pts)
if s:
    write_dat(os.path.join(OUT, 'fig05.dat'), s)
    plot('fig05_tool_comparison',
         'Same receiver, two load generators: iperf3 pacing fabricates loss below the ceiling',
         'Offered rate (Gbit/s)', 'fig05.dat', list(s),
         'ladder_ring128smooth_*, tools_*')

# ---------------------------------------------------------------- fig06
# 캐시 공유 수준 x rcvbuf
s = {}
d = newest('l2hyp_*')
for arm, lbl in (('same', 'same core (shares L2 + L3)'),
                 ('l2split', 'same socket (shares L3 only)'),
                 ('l3split', 'cross socket (shares nothing)')):
    pts = [(CAPS[r[1]], float(r[4])) for r in rows(d)
           if r[0] == arm and r[2] == '0' and r[4] != 'NA' and r[1] in CAPS]
    if pts: s[lbl] = agg(pts)
if s:
    write_dat(os.path.join(OUT, 'fig06.dat'), s)
    plot('fig06_cache_sharing',
         'The buffer penalty scales with the cache the producer and consumer share (blast)',
         'sk_rcvbuf (KiB)', 'fig06.dat', list(s), os.path.basename(d or ''), logx=True)

# ---------------------------------------------------------------- fig07
# MTU 1500 rcvbuf 스윕
s = {}
d = newest('mtu1500_tune_*')
for rate in ('28', '32'):
    pts = []
    for r in rows(d):
        if not r[0].startswith('A_') or r[1] != rate: continue
        cap = r[0][2:]
        rx = r[3].split('=')[1] if '=' in r[3] else r[3]
        if cap in CAPS and rx != 'NA':
            pts.append((CAPS[cap], float(rx)))
    if pts: s[f'offered {rate} Gbit/s'] = agg(pts)
if s:
    write_dat(os.path.join(OUT, 'fig07.dat'), s)
    plot('fig07_mtu1500_rcvbuf',
         'MTU 1500: the buffer curve is flat above 512KB (no inverted-U)',
         'sk_rcvbuf (KiB)', 'fig07.dat', list(s), os.path.basename(d or ''), logx=True)

# ---------------------------------------------------------------- fig08
# shed 윈도 길이 x throughput, 부하별.  컨트롤러 필요 여부를 가르는 그림.
d = newest('shedwin_*')
s = {}
for rate in ('52', '60', '72'):
    pts = [(int(r[0]) if r[0] != '0' else 12, float(r[2]))
           for r in rows(d) if r[1] == rate and len(r) > 2]
    if pts: s[f'offered {rate} Gbit/s'] = agg(pts)
if s:
    write_dat(os.path.join(OUT, 'fig08.dat'), s)
    plot('fig08_shed_window',
         'Shed window vs goodput, by offered rate (leftmost point = shed off)',
         'Shed window (us)', 'fig08.dat', list(s), os.path.basename(d or ''),
         logx=True,
         extra='set xtics ("off" 12, "25" 25, "50" 50, "100" 100, "200" 200, '
               '"400" 400, "800" 800, "1600" 1600)')

# ---------------------------------------------------------------- fig09
# config 레버(MAX_HEAD 64 + HARDENED_USERCOPY=n) 전후 + shed on/off
d4 = newest('cfglever_*')
s = {}
for sh, tag in (('0', 'shed off'), ('1', 'shed on')):
    pts = [(int(r[1]), float(r[2])) for r in rows(d4) if r[0] == sh]
    if pts: s[f'udpopt4 ({tag})'] = agg(pts)
# udpopt3 기준선 (직전 커널, shed 윈도 200us) — 같은 도구/ring 이라 비교 가능
prev = {'shed off': [(48,47.8),(52,45.15),(56,41.8),(60,41.78)],
        'shed on':  [(48,47.9),(52,51.82),(56,48.5),(60,48.75)]}
for tag, pts in prev.items():
    s[f'udpopt3 ({tag})'] = [(x, y, 0.0) for x, y in pts]
if s:
    write_dat(os.path.join(OUT, 'fig09.dat'), s)
    plot('fig09_config_levers',
         'Shrinking the mlx5 head copy and dropping the usercopy check, with and without shed',
         'Offered rate (Gbit/s)', 'fig09.dat', list(s), os.path.basename(d4 or ''))

# ---------------------------------------------------------------- fig10  ★ 메커니즘 확정
# 워킹셋(ring descriptor + rcvbuf) x throughput, PMU L3 miss 동반.
# ring 128 과 1024 의 점들이 하나의 곡선 위에 올라가면 워킹셋이 지배 변수라는 증거.
# descriptor 추정: ring/1024 * 16MB (MPWQE 64 pages, MTU 9000)
d = newest('cachecnt_*')            # ring 1024
d2 = sorted(glob.glob(os.path.join(LOGS, 'cachecnt_*')))
CAPMB = {'256K':0.25, '1M':1, '4M':4, '16M':16}
pts, l3pts = [], []
for dd in d2:
    for r in rows(dd):
        ring, cap = r[0], r[1]
        if cap not in CAPMB: continue
        desc = int(ring) / 1024.0 * 16.0
        ws = desc + CAPMB[cap]
        pts.append((round(ws, 2), float(r[2])))
        h, m = float(r[7]), float(r[8])
        l3pts.append((round(ws, 2), 100.0 * m / (h + m) if (h + m) > 0 else 0.0))
if pts:
    s2 = {'goodput (Gbit/s)': agg(pts)}
    write_dat(os.path.join(OUT, 'fig10.dat'), s2)
    write_dat(os.path.join(OUT, 'fig10b.dat'), {'L3 load-miss (%)': agg(l3pts)})
    gp = os.path.join(OUT, 'fig10_working_set.gp')
    png = os.path.join(OUT, 'fig10_working_set.png')
    open(gp, 'w').write(f"""set terminal pngcairo size 1000,650 noenhanced font "Sans,11"
set output "{png}"
set title "Working set, not the individual knob, predicts the cliff (offered 44 Gbit/s)" font "Sans,13"
set xlabel "Working set = Rx ring descriptor pages + sk_rcvbuf (MiB)"
set ylabel "Goodput (Gbit/s)"
set y2label "L3 load-miss (%)"
set ytics nomirror
set y2tics
set grid
set key outside right top
set logscale x 2
set xtics (2,4,8,16,32)
set arrow from 18,graph 0 to 18,graph 1 nohead lc rgb "#cc0000" dt 2 lw 2
set label "L3 = 18 MiB" at 18.4,graph 0.30 tc rgb "#cc0000" font "Sans,10"
set label "source: cachecnt_* (ring 128 and 1024 pooled)" at screen 0.01,0.02 font "Sans,8" tc rgb "#666666"
set bmargin 5
plot "{os.path.join(OUT,'fig10.dat')}" index 0 using 1:2:3 with yerrorlines lw 2 pt 7 ps 1.3 axes x1y1 title "goodput", \
     "{os.path.join(OUT,'fig10b.dat')}" index 0 using 1:2:3 with yerrorlines lw 2 pt 5 ps 1.2 axes x1y2 title "L3 load-miss"
""")
    subprocess.run(['gnuplot', gp], check=True)
    print('wrote', png)

# ---------------------------------------------------------------- fig11  ★ 인과 확정
# Intel CAT 으로 L3 를 줄이면 절벽이 따라 내려오는가.
# ring 128 고정(descriptor 2MB) -> 워킹셋 = 2MB + rcvbuf
CAPMB2 = {'256K': 0.25, '1M': 1, '2M': 2, '4M': 4, '8M': 8, '16M': 16}
s = {}
for lbl, pat in (('L3 = 18 MiB (12 ways)', 'cat_12way_*'),
                 ('L3 = 9 MiB (6 ways)', 'cat_6way_*'),
                 ('L3 = 4.5 MiB (3 ways)', 'cat_3way_*')):
    d = newest(pat)
    pts = [(2 + CAPMB2[r[1]], float(r[2])) for r in rows(d) if r[1] in CAPMB2]
    if pts:
        s[lbl] = agg(pts)
if s:
    write_dat(os.path.join(OUT, 'fig11.dat'), s)
    plot('fig11_cat_ways',
         'Shrinking the LLC with Intel CAT moves the cliff down with it (offered 44 Gbit/s)',
         'Working set = ring descriptor pages + sk_rcvbuf (MiB)', 'fig11.dat',
         list(s), 'cat_{12,6,3}way_*', logx=True, extra='set xtics (2,4,8,16)')

print('\nfigures in', OUT)
