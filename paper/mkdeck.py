#!/usr/bin/env python3
"""랩미팅용 PPT: 우리가 커널에서 고친 것.

한글 폰트는 이 control node 에 없지만 pptx 는 XML 만 쓰므로 상관없다 -
렌더링은 Windows 의 PowerPoint 가 하고 거기엔 맑은 고딕이 있다.
(그래프 PDF/PNG 는 gnuplot 이 렌더한 것이라 영문으로 만들어 뒀다.)
"""
import os
from pptx import Presentation
from pptx.util import Inches, Pt, Emu
from pptx.dml.color import RGBColor
from pptx.enum.text import PP_ALIGN, MSO_ANCHOR

HERE = os.path.dirname(os.path.abspath(__file__))
FIGS = f"{HERE}/figs"
OUT = f"{HERE}/UDP_kernel_changes.pptx"

NAVY  = RGBColor(0x1B, 0x49, 0x65)
RED   = RGBColor(0xC1, 0x66, 0x6B)
OLIVE = RGBColor(0x8D, 0x87, 0x41)
GRAY  = RGBColor(0x55, 0x55, 0x55)
DARK  = RGBColor(0x22, 0x22, 0x22)
PALE  = RGBColor(0xEF, 0xF3, 0xF6)
WHITE = RGBColor(0xFF, 0xFF, 0xFF)

KR = '맑은 고딕'
MONO = 'Consolas'

prs = Presentation()
prs.slide_width = Inches(13.333)
prs.slide_height = Inches(7.5)
BLANK = prs.slide_layouts[6]
W = prs.slide_width


def slide():
    return prs.slides.add_slide(BLANK)


def textbox(s, x, y, w, h):
    tb = s.shapes.add_textbox(Inches(x), Inches(y), Inches(w), Inches(h))
    tf = tb.text_frame
    tf.word_wrap = True
    return tf


def para(tf, text, size=16, color=DARK, bold=False, font=KR, space=6, first=False,
         align=PP_ALIGN.LEFT, indent=0):
    p = tf.paragraphs[0] if first else tf.add_paragraph()
    p.alignment = align
    p.space_after = Pt(space)
    p.level = indent
    for i, chunk in enumerate(text.split('**')):
        if not chunk:
            continue
        r = p.add_run()
        r.text = chunk
        r.font.size = Pt(size)
        r.font.name = font
        r.font.bold = bold or (i % 2 == 1)
        r.font.color.rgb = color if i % 2 == 0 else NAVY
    return p


def header(s, title, sub=None, accent=NAVY):
    bar = s.shapes.add_shape(1, 0, 0, W, Inches(0.09))
    bar.fill.solid(); bar.fill.fore_color.rgb = accent
    bar.line.fill.background()
    tf = textbox(s, 0.55, 0.3, 12.3, 1.0)
    para(tf, title, size=30, color=accent, bold=True, first=True)
    if sub:
        para(tf, sub, size=14, color=GRAY, space=0)
    return 1.55 if sub else 1.35


def code(s, lines, x, y, w, h, size=12):
    box = s.shapes.add_shape(1, Inches(x), Inches(y), Inches(w), Inches(h))
    box.fill.solid(); box.fill.fore_color.rgb = PALE
    box.line.color.rgb = RGBColor(0xD5, 0xDC, 0xE2)
    tf = box.text_frame
    tf.word_wrap = False
    tf.margin_left = Inches(0.18); tf.margin_top = Inches(0.12)
    tf.margin_right = Inches(0.1); tf.margin_bottom = Inches(0.1)
    for i, ln in enumerate(lines):
        p = tf.paragraphs[0] if i == 0 else tf.add_paragraph()
        p.space_after = Pt(1)
        hot = ln.startswith('>')
        for j, chunk in enumerate((ln[1:] if hot else ln).split('**')):
            if not chunk:
                continue
            r = p.add_run()
            r.text = chunk
            r.font.size = Pt(size)
            r.font.name = MONO
            r.font.color.rgb = RED if hot else DARK
            r.font.bold = hot or (j % 2 == 1)
    return box


def table(s, rows, x, y, w, h, size=12, headfill=NAVY, colw=None):
    nr, nc = len(rows), len(rows[0])
    shp = s.shapes.add_table(nr, nc, Inches(x), Inches(y), Inches(w), Inches(h))
    t = shp.table
    if colw:
        total = sum(colw)
        for i, cw in enumerate(colw):
            t.columns[i].width = Emu(int(Inches(w) * cw / total))
    for i, row in enumerate(rows):
        t.rows[i].height = Inches(h / nr)
        for j, cell in enumerate(row):
            c = t.cell(i, j)
            c.vertical_anchor = MSO_ANCHOR.MIDDLE
            c.margin_left = Inches(0.08); c.margin_right = Inches(0.06)
            c.margin_top = Inches(0.02); c.margin_bottom = Inches(0.02)
            tf = c.text_frame
            tf.word_wrap = True
            p = tf.paragraphs[0]
            p.alignment = PP_ALIGN.LEFT if j == 0 else PP_ALIGN.CENTER
            for k, chunk in enumerate(str(cell).split('**')):
                if not chunk:
                    continue
                r = p.add_run()
                r.text = chunk
                r.font.size = Pt(size)
                r.font.name = KR
                r.font.bold = (i == 0) or (k % 2 == 1)
                r.font.color.rgb = WHITE if i == 0 else (NAVY if k % 2 == 1 else DARK)
            if i == 0:
                c.fill.solid(); c.fill.fore_color.rgb = headfill
            else:
                c.fill.solid()
                c.fill.fore_color.rgb = WHITE if i % 2 else RGBColor(0xF7, 0xF9, 0xFA)
    return t


def note(s, text, y=6.72, color=GRAY, size=12):
    tf = textbox(s, 0.55, y, 12.3, 0.55)
    para(tf, text, size=size, color=color, first=True)


def pic(s, name, x, y, h):
    p = f"{FIGS}/{name}"
    if os.path.exists(p):
        s.shapes.add_picture(p, Inches(x), Inches(y), height=Inches(h))


# ───────────────────────────── 1. 표지 ─────────────────────────────
s = slide()
bg = s.shapes.add_shape(1, 0, 0, W, prs.slide_height)
bg.fill.solid(); bg.fill.fore_color.rgb = NAVY; bg.line.fill.background()
tf = textbox(s, 1.0, 2.2, 11.3, 3.0)
para(tf, "Linux UDP 수신 경로 재설계", size=44, color=WHITE, bold=True, first=True)
para(tf, "커널에서 무엇을 고쳤는가", size=26, color=RGBColor(0xBF, 0xD4, 0xE0), space=24)
para(tf, "수신 버퍼 상한은 메모리가 아니라 producer/consumer 가 공유하는 캐시에서 유도되어야 한다",
     size=17, color=RGBColor(0xDCE7, 0xEE, 0xF4) if False else RGBColor(0xDC, 0xE7, 0xF0))
para(tf, "6.18.53-udpopt20   ·   patch 0009   ·   네트워크시스템설계 텀프로젝트",
     size=13, color=RGBColor(0x9F, 0xBA, 0xCA), space=0)

# ───────────────────────────── 2. 문제 요약 ─────────────────────────────
s = slide()
y = header(s, "고치기 전: 문제 다섯 개", "줄 번호는 순정 6.18.53 기준")
code(s, [
    "   sender",
    "     │",
    "  ┌──▼──────────────────────────────────────────────┐",
    "  │ ① NIC DMA → RX ring        ethtool -G (관리자)   │",
    "  ├──▼──────────────────────────────────────────────┤",
    "  │ ② NAPI poll                rx-frames (DIM 자동)  │",
    "  ├──▼──────────────────────────────────────────────┤",
    "  │ ③ GRO                      en_rx.c:1653         │",
    "  ├──▼──────────────────────────────────────────────┤",
    "  │ ④ ip_rcv / udp_rcv         udp.c:2919           │",
    "  ├──▼──────────────────────────────────────────────┤",
    "  │ ⑤ udp_queue_rcv_skb        udp.c:2497           │",
    "  ├──▼──────────────────────────────────────────────┤",
    ">  │ ⑥ __udp_enqueue_schedule_skb   udp.c:1699       │",
    ">  │      if (rmem + size > rcvbuf) goto drop;  1723 │  ← 폐기",
    "  ├──▼──────────────────────────────────────────────┤",
    "  │ ⑦ recvmsg → reader_queue   udp.c:1953           │",
    "  ├──▼──────────────────────────────────────────────┤",
    "  │ ⑧ skb_copy_datagram_msg    udp.c:2106  (유일한 복사) │",
    "  └─────────────────────────────────────────────────┘",
], 0.55, y, 6.4, 5.0, size=10.5)

tf = textbox(s, 7.25, y, 5.6, 5.0)
para(tf, "P1  sk_rcvbuf 는 정적이고 정할 주체가 없다", size=15, bold=True, color=RED, first=True)
para(tf, "READ_ONCE 만 있고 갱신 코드가 없다. TCP 의 DRS 에 해당하는 것이 UDP 엔 없다.", size=12, color=GRAY)
para(tf, "P2  총량을 보는 주체가 없다", size=15, bold=True, color=RED, space=2)
para(tf, "udp_mem 은 RAM 기반(nr_free_buffer_pages()/8). 캐시 크기를 보는 코드 grep 0건.", size=12, color=GRAY)
para(tf, "P3  큰 버퍼의 비용은 메모리가 아니라 캐시 핸드오프", size=15, bold=True, color=RED, space=2)
para(tf, "공유 캐시가 없으면 512K↔18M 비가 0.94로 효과 소멸. 비용은 '복사'가 아니라 '어디서 읽느냐'.", size=12, color=GRAY)
para(tf, "P4  버릴 패킷에 일을 다 쓰고 버린다", size=15, bold=True, color=RED, space=2)
para(tf, "폐기 지점이 ①~⑤ 뒤. 과부하에서 자기 강화 루프 → 처리량이 평탄이 아니라 하강.", size=12, color=GRAY)
para(tf, "P5  버퍼는 소켓별인데 병목은 큐별", size=15, bold=True, color=RED, space=2)
para(tf, "ring(관리자) / rx-frames(DIM) / sk_rcvbuf(앱) — 세 주체, 세 제약, 서로 모름.", size=12, color=GRAY)

# ───────────────────────────── 3. 기여 요약 ─────────────────────────────
s = slide()
y = header(s, "고친 것 네 가지", "‘동적으로 바꾼다’가 새로운 게 아니다 — 무엇이 새로운지가 중요")
table(s, [
    ["", "기전", "새로운 부분", "선례", "고치는 문제"],
    ["M1", "동적 sk_rcvbuf sizing", "RTT 없이 쓸 **대체 시계**를 찾은 것", "TCP DRS", "P1"],
    ["M2", "**캐시에서 유도한 전역 상한**", "상한의 **출처가 캐시** + 소켓 사이 **전역**", "**없음**", "P2 P3"],
    ["M3", "드라이버 조기 폐기", "버리는 **위치**", "CoDel 계열", "P4"],
    ["M4", "**드라이버→소켓 ring 보고**", "**인터페이스 자체가 없던 것**", "없음", "P5"],
], 0.55, y, 12.25, 2.5, size=14, colw=[0.6, 2.6, 4.6, 1.5, 1.4])

tf = textbox(s, 0.55, y + 2.85, 12.25, 2.2)
para(tf, "M2 가 논문의 논지다.", size=20, bold=True, color=NAVY, first=True)
para(tf, "커널 전체에 cache_size | llc_size | l3_size 를 보는 코드가 0건 (6.18.53, 7.2.7 둘 다).", size=15)
para(tf, "M1 은 M2 를 쓸 수 있게 하는 기계장치, M3 는 별개의 상보적 레버, M4 는 M2 의 이식성을 만드는 배관.", size=15)
para(tf, "M4 를 빼면 pct 가 다시 손으로 박는 상수가 되고 이식성 주장이 통째로 무너진다.", size=15, color=RED)
note(s, "코드에서 찾기:   grep -rn \"UDP-optimize\" <kernel-tree>", size=13)

# ───────────────────────────── 4. M1 시계 ─────────────────────────────
s = slide()
y = header(s, "M1. 동적 sizing — 문제는 ‘시계’였다", "net/ipv4/udp.c:2007  udp_rcvbuf_autotune()")
tf = textbox(s, 0.55, y, 12.25, 0.9)
para(tf, "TCP DRS 는 RTT 마다 평가한다. RTT 는 ‘소비자가 한 바퀴 도는 시간’이라는 자를 공짜로 준다. "
         "UDP 엔 ACK 이 없어 RTT 가 없고, 만들 수도 없다 — 그래서 아무도 UDP 판 DRS 를 안 썼다.", size=15, first=True)
para(tf, "우리는 주기의 정의를 바꿨다: **큐가 찼다가 비는 한 사이클**.", size=17, color=NAVY)

table(s, [
    ["", "TCP DRS  (tcp_input.c:933)", "우리  (udp.c:2007)"],
    ["시계", "RTT (ACK 으로 관측)", "**비움 → 비움** (점유율로 관측)"],
    ["측정량", "1 RTT 동안 유저가 가져간 바이트", "**1 주기에 소비자가 가져간 바이트**"],
    ["목표", "2 × 그 값", "2 × 그 값"],
    ["상한", "tcp_rmem[2] = 사람이 박은 32MB", "**L3 − ring bytes** (기계에서 유도)"],
    ["축소", "없음 (성장만)", "있음 (1/8 미만, 4배 데드밴드)"],
    ["소켓 간", "없음 (각자 상한까지)", "**전역 예산 + 균등 회수**"],
], 0.55, y + 1.05, 7.3, 3.1, size=13, colw=[1.0, 3.0, 3.3])

code(s, [
    "/* 주기의 앞 절반 */",
    "if (rmem > (rcvbuf >> 1))",
    "        atomic_set(&up->rcvbuf_filled, 1);",
    "",
    "/* 뒷 절반 — edge trigger */",
    "if (rmem < (rcvbuf >> 3)) {",
    "    if (atomic_xchg(&up->rcvbuf_filled, 0)) {",
    "        int took =",
    "          atomic_xchg(&up->rcvbuf_consumed, 0);",
    ">        atomic_set(&up->rcvbuf_target, took*2);",
    "    }",
], 8.1, y + 1.05, 4.7, 2.5, size=11)

tf = textbox(s, 8.1, y + 3.65, 4.7, 0.9)
para(tf, "점유 깊이가 아니라 **소비량**을 쓴다.", size=13, bold=True, first=True)
para(tf, "깊이는 sk_rcvbuf 가 위를 막아서, 크면 더 깊어지고 → 추정치 상승 → 더 커지는 루프. "
         "실측 9.4MB 까지 감 (1MB 가 더 나은 소켓).", size=11, color=GRAY)
note(s, "왜 edge-trigger 인가: level 이면 빈 큐에 패킷 하나 들어올 때마다 ‘주기 완성’이 되어 목표가 "
        "‘패킷 한 개’로 덮어써진다 (v12 에서 55.45 → 36.70).")

# ───────────────────────────── 5. M1 동작 추적 ─────────────────────────────
s = slide()
y = header(s, "M1. 실제로 어떻게 자라나", "MTU 9000 · 56 Gb/s · DIM 이 rx-frames=128 에 정착 → NAPI poll 한 번 = 1.15 MB")
code(s, [
    "사이클 0   시작 sk_rcvbuf = 208K,  target = 0",
    "           skb3 에서 rmem 114K > half 104K  →  성장 분기",
    ">          그러나 target == 0  →  못 자란다   (수요를 아직 모른다)",
    "           skb4 부터 DROP.  20개 중 3개만 수신",
    "           소비자가 171K 꺼내감  →  rcvbuf_consumed = 171K",
    "",
    "사이클 1   skb1: rmem 0 < 26K,  xchg(filled,0)==1  →  **주기 완성**",
    ">                target = took × 2 = 342K",
    "           skb3: 114K > 104K,  target 342K > 208K   →  +64K → 272K",
    "           skb4:                                    →  +64K → 336K",
    "           skb5:                                    →  +64K → 342K (target 도달)",
    "           skb6: rcvbuf >= target  →  성장 중단",
    "",
    "사이클 2~4  took 342K → target 684K → rcvbuf 684K",
    "            took 684K → target 1.37M → rcvbuf 1.37M",
    ">           took 1.15M → target **2.30M** → rcvbuf 2.30M   ← 여기서 멈춤",
], 0.55, y, 7.7, 4.4, size=11.5)

tf = textbox(s, 8.45, y, 4.4, 4.6)
para(tf, "왜 2.3 MB 에서 멈추나", size=18, bold=True, color=NAVY, first=True)
para(tf, "took 은 도착한 양으로 위가 막혀 있다. 버퍼가 버스트 전체(1.15MB)를 담으면 "
         "그 뒤로는 아무리 커져도 took 이 안 늘어난다.", size=13)
para(tf, "멈추는 이유가 ‘예산’이 아니라 **‘수요’**다.", size=14, bold=True, color=RED)
para(tf, "", size=6)
para(tf, "유도값   2 × (128 × 8972B) = **2.30 MB**", size=14, font=MONO)
para(tf, "실측     조건별 최적 static = **2 MB**", size=14, font=MONO)
para(tf, "", size=6)
para(tf, "손으로 찾은 최적값을 식이 자동으로 뽑는다.", size=14, bold=True, color=NAVY)
para(tf, "수렴: 4~5 사이클 ≈ 1 ms 미만", size=13, color=GRAY)
note(s, "소비자가 못 따라가는 소켓은 큐가 rcvbuf/8 아래로 안 내려가 → 주기가 안 끝나 → target 이 0 → "
        "한 번도 안 자란다. 별도 판정 없이 버스트형/소비부족형이 갈린다.")

# ───────────────────────────── 6. M1 결과 ─────────────────────────────
s = slide()
y = header(s, "M1. 결과 — 어떤 정적 값도 두 워크로드를 다 잡지 못한다", "N=5, DIM on, 같은 커널 · 같은 설정")
table(s, [
    ["정책", "W1  (1소켓 × 56G, 버스트)", "W2  (8소켓 × 7G, 워킹셋)", "최악"],
    ["정적 1M", "32.14", "55.66", "32.14"],
    ["정적 8M", "55.41", "23.17", "23.17"],
    ["**autotune**", "**55.32**", "**55.58**", "**55.32**"],
], 0.55, y, 7.4, 1.9, size=16, colw=[1.6, 2.2, 2.2, 1.0])

tf = textbox(s, 0.55, y + 2.15, 7.4, 2.4)
para(tf, "같은 커널, 같은 설정에서 버퍼가 스스로 갈린다:", size=16, first=True)
para(tf, "W1 → **4.4 M 하나**        W2 → **1.1 M 여덟 개**", size=18, font=MONO)
para(tf, "", size=4)
para(tf, "정직하게: DIM off 에서는 정적 1M 이 근소하게 낫다 (W1 48.09 vs 45.65). "
         "버스트가 없으면 조절할 게 없고 조절 비용만 남는다.", size=13, color=GRAY)

tf = textbox(s, 8.15, y, 4.7, 4.6)
para(tf, "여기까지 오는 데 버그 셋", size=18, bold=True, color=RED, first=True)
para(tf, "전부 ‘측정 없이 고치다’ 유형", size=12, color=GRAY)
para(tf, "v12  W1 55.45 → 36.70", size=14, bold=True, space=2)
para(tf, "목표 갱신이 level-triggered. 맞게 잡힌 목표가 µs 뒤 ‘패킷 한 개’로 덮어써짐", size=12, color=GRAY)
para(tf, "v13  개선 없음", size=14, bold=True, space=2)
para(tf, "축소를 고쳤는데 축소가 원인이 아니었다. 진단 없이 그럴듯한 곳을 고침", size=12, color=GRAY)
para(tf, "v14  W2 → 37.63", size=14, bold=True, space=2)
para(tf, "예산이 autotune 증분만 계상. 8소켓 × 기본 1M = 8MB 가 안 보임", size=12, color=GRAY)
para(tf, "교훈", size=14, bold=True, color=NAVY, space=2)
para(tf, "처리량만 보면 ‘조금 나쁘다’지만 ss -uam 의 rb 를 보면 1M 고정이 바로 보인다. "
         "autotune 실험은 항상 소켓별 rcvbuf 를 같이 기록할 것.", size=12, color=GRAY)

# ───────────────────────────── 7. M2 예산식 ─────────────────────────────
s = slide()
y = header(s, "M2. 캐시에서 유도한 전역 상한  ★ 논지", "net/ipv4/udp.c:1721  udp_cache_budget_init() / udp_cache_budget()")
code(s, [
    "/* 순정: RAM 기반 */",
    "limit = nr_free_buffer_pages() / 8;        /* udp.c:4039 */",
    "     →  RAM 128GB 면 상한 16GB.   L3 는 18MB.",
    ">       세 자릿수 엉뚱한 자원을 재고 있다",
    "",
    "/* 우리: 부팅 시 캐시 토폴로지를 읽는다 */",
    "static int __init udp_cache_budget_init(void) {",
    "        ci = get_cpu_cacheinfo(raw_smp_processor_id());",
    "        /* 가장 높은 레벨의 DATA/UNIFIED 리프 */",
    "        udp_llc_bytes = size;",
    ">       pr_info(\"UDP: receive budget sized from L%u cache (%u KiB)\\n\", ...);",
    "}  late_initcall(udp_cache_budget_init);",
    "",
    "static long udp_cache_budget(unsigned int pct) {",
    ">       long avail = (long)udp_llc_bytes - net_rx_ring_bytes();   /* ← M4 */",
    "        if (avail < 0) avail = 0;",
    "        return avail * pct / 100;",
    "}",
], 0.55, y, 7.5, 4.0, size=11)

tf = textbox(s, 8.25, y, 4.6, 1.0)
para(tf, "부팅 로그", size=14, bold=True, color=NAVY, first=True)
para(tf, "UDP: receive budget sized from L3 cache (18432 KiB)", size=11, font=MONO)
table(s, [
    ["ring", "ring bytes", "예산 (pct **50 고정**)", "처리량"],
    ["128", "2 MB", "**8.0 MB**", "52.7"],
    ["1024 (드라이버 기본)", "16 MB", "**1.0 MB**", "51.8"],
], 8.25, y + 1.1, 4.6, 1.4, size=12, colw=[1.7, 1.0, 1.3, 0.9])
tf = textbox(s, 8.25, y + 2.65, 4.6, 1.8)
para(tf, "pct 를 한 번도 안 건드리고 허용량이 8배 달라진다.", size=14, bold=True, color=NAVY, first=True)
para(tf, "이게 이식성 주장의 전부다 — 다른 기계에 옮기면 그 기계의 L3 와 그 NIC 의 ring 으로 "
         "자동으로 다른 답이 나온다.", size=12, color=GRAY)
note(s, "정직하게: net_rx_ring_bytes() 는 **상한**이지 실측 점유량이 아니다. 아직 안 쓴 페이지는 L3 에 없다. "
        "식이 맞아서가 아니라 **답이 맞아서** 쓰고 있다 — Intel CMT(llc_occupancy)로 직접 잴 수 있고, 아직 안 했다.")

# ───────────────────────────── 8. M2 설계 결정 ─────────────────────────────
s = slide()
y = header(s, "M2. 설계 결정 네 개 — 전부 측정이 강제했다")
rows = [
    ["", "택한 것", "왜 (측정)"],
    ["무엇을 세나", "점유량이 아니라 **나눠준 용량**\n(udp_rcvbuf_granted)",
     "소비자가 따라가면 큐가 거의 비어서, 8MB 를 나눠준 상태에서 실측 0.75MB 만 잡힌다. **예산이 안 문다**"],
    ["시작 버퍼", "**한 번 계상**\ncmpxchg(granted, 0, rcvbuf)",
     "증분만 세면 8소켓 × 기본 1M = 8MB 가 안 보인다. 9MB 예산에 17.8MB 를 주고 **37.63** (정적 1M 은 55.70)"],
    ["생성 시 거절?", "**아니오. 사후 균등 회수**\nmax(budget/n, SOCK_MIN_RCVBUF)",
     "거절하면 먼저 온 소켓이 8MB, 나머지 일곱이 0. 균등 회수는 8소켓이 각 1.1MB 로 수렴 — 실측 최적(1MB)과 잡음 안"],
    ["SO_RCVBUF 소켓", "**거절 않고 계상만**",
     "요청은 온전히 존중. 대신 **다른 소켓이 옆에서 계속 자라는 것**을 막는다. 64MB 는 여덟 번째가 되기 전엔 안전하다"],
]
table(s, rows, 0.55, y, 12.25, 3.5, size=12, colw=[1.5, 3.0, 7.0])

tf = textbox(s, 0.55, y + 3.7, 12.25, 1.4)
para(tf, "그리고 유휴 회수 워커 — 축소는 패킷 도착 시에만 평가되므로, sender 가 멈추면 회수 경로가 없다.", size=15, bold=True, first=True)
para(tf, "실측: 3소켓이 4MB 로 자란 뒤 침묵하면, 새로 온 56G 소켓이 1M 에 묶여 **33.4** (그 셋을 닫으면 55.5). "
         "워커는 다른 소켓이 거절당했을 때만 arm 된다 — 경쟁 없는 기계는 아예 안 돈다.", size=13, color=GRAY)
note(s, "결과:   8M × 8소켓   22.47  →  **54.99**   (+145%)", size=15, color=NAVY)

# ───────────────────────────── 9. M2 결과 그림 ─────────────────────────────
s = slide()
y = header(s, "M2 + M1. 다수 sender → 소켓 하나 (fan-in)",
           "sender 는 두 모드가 완전히 동일 — 프로세스 수 · 코어 · 총 제공률 88G. 다른 건 목적지 포트뿐")
pic(s, "nn_tput_fanin_m9000.png", 0.5, y, 3.0)
pic(s, "nn_tput_nn_m9000.png", 4.7, y, 3.0)
tf = textbox(s, 8.95, y, 3.9, 3.3)
para(tf, "기존 UDP 의 회복은 소켓 수 덕분이었다", size=15, bold=True, color=RED, first=True)
para(tf, "n:n  plain   12.13 → 38.19\nfan-in plain  12.81 → 13.19", size=12, font=MONO)
para(tf, "소켓이 늘면 208KB × n 이 늘 뿐. 프로토콜 개선이 아니라 **우연**.", size=12, color=GRAY)
para(tf, "우리는 fan-in 에서 거의 평탄", size=15, bold=True, color=NAVY, space=2)
para(tf, "51.7 / 51.3 / 51.6 / 47.6 / 43.7", size=12, font=MONO)
para(tf, "n=4 에서 기존 최선 대비 ×2.6, TCP 보다도 +21%", size=12, color=GRAY)
table(s, [
    ["n", "plain", "sockopt", "**ours**", "tcp"],
    ["1", "12.81", "24.45", "**51.67**", "54.56"],
    ["2", "10.51", "19.83", "**51.33**", "47.06"],
    ["4", "10.10", "20.12", "**51.59**", "42.74"],
    ["8", "8.74", "18.54", "**47.56**", "40.77"],
    ["16", "13.19", "20.30", "**43.70**", "34.15"],
], 0.55, y + 3.25, 8.1, 1.85, size=12, colw=[0.6, 1.2, 1.2, 1.2, 1.2])
note(s, "MTU 9000, N=5, FLAKE 0건 / 400 시행.   fan-in 은 TCP 가 구조적으로 할 수 없는 경우다 — "
        "연결마다 소켓이 생기는 게 TCP 정의라, 이 문제는 TCP 에서 베껴올 데가 없다.", y=6.85)

# ───────────────────────────── 10. M3 신호 경로 ─────────────────────────────
s = slide()
y = header(s, "M3. 드라이버 조기 폐기 — 기준과 신호 경로", "메시지도 콜백도 없다. 큐 번호 한 칸에 만료 시각을 찍는다")
code(s, [
    "/* ① 신호를 만드는 쪽 — 실제 폐기가 유일한 트리거   udp.c:2960 */",
    "rc = __udp_enqueue_schedule_skb(sk, skb);",
    "if (rc == -ENOMEM) {                       /* 소켓 버퍼 넘침 */",
    ">       if (sysctl_udp_rx_shed) udp_rx_shed_mark(sk, skb);",
    "}",
    "",
    "/* ② 신호 자체 — 큐 한 칸에 만료 시각   udp.c:2917 */",
    "void udp_rx_shed_mark(...) {",
    ">       if (!skb_rx_queue_recorded(skb)) return;   /* 모르면 추측 안 함 */",
    ">       q = skb_get_rx_queue(skb);                 /* 소켓 아닌 **패킷**에서 */",
    "        WRITE_ONCE(udp_rx_shed[q].until_ns,",
    "                   ktime_get_mono_fast_ns() + us * NSEC_PER_USEC);",
    "}",
    "",
    "/* ③ 읽는 쪽 — CQE 를 보는 순간   mlx5/en_rx.c:89 */",
    "until = READ_ONCE(udp_rx_shed[rq->ix].until_ns);",
    "if (likely(!until)) return false;          /* 평상시: 필드 읽기 하나 */",
    "if (now >= until) { WRITE_ONCE(...,0); return false; }   /* 자동 해제 */",
    ">return get_cqe_l4_hdr_type(cqe) == CQE_L4_HDR_TYPE_UDP;  /* UDP 만 */",
    "",
    "/* ④ 적용   en_rx.c:1912, :2552 */",
    ">if (unlikely(mlx5e_udp_rx_shed(rq, cqe))) goto wq_cyc_pop;  /* skb 생성 전 */",
], 0.55, y, 7.9, 4.6, size=10.5)

tf = textbox(s, 8.65, y, 4.2, 4.8)
para(tf, "기준 = 예측이 아니라 사후 사실", size=15, bold=True, color=NAVY, first=True)
para(tf, "‘곧 넘칠 것 같다’가 아니라 **‘방금 실제로 버렸다’**. 새 임계값을 도입하지 않는다.", size=12, color=GRAY)
para(tf, "self-clocking pulse", size=15, bold=True, color=NAVY, space=2)
para(tf, "끄는 신호가 없다. 계속 실패하면 창이 갱신되고, 성공하면 갱신이 멈춰 저절로 풀린다. "
         "상태 기계도 해제 경로도 없다.", size=12, color=GRAY)
para(tf, "무엇을 절약하나", size=15, bold=True, color=NAVY, space=2)
para(tf, "skb 할당 · GRO · IP 조회 · 체크섬 · 소켓 조회 · (GRO 미설정 시) 재분할", size=12, color=GRAY)
para(tf, "배달 바이트당 명령어  0.88 → **0.53**", size=13, font=MONO)
note(s, "v11 버그: 예전엔 sk_rx_queue_get(sk) 를 썼는데 그건 connected 소켓에서만 유지된다. "
        "unconnected 다중 sender 소켓은 −1 을 돌려주고 fallback 이 q=0 으로 바꿔 → **모든 shed 가 큐 0 으로만** 갔다.")

# ───────────────────────────── 11. M3 결과 + 한계 ─────────────────────────────
s = slide()
y = header(s, "M3. 결과, 그리고 미해결 결함", accent=RED)
table(s, [
    ["offered", "shed off", "shed on"],
    ["48 G", "47.8", "47.9  (무해)"],
    ["52 G", "45.15", "**51.82**"],
    ["60 G", "41.78", "**48.75**"],
], 0.55, y, 3.5, 1.7, size=14)
tf = textbox(s, 0.55, y + 1.95, 3.5, 1.8)
para(tf, "창 길이 50 µs 는 스윕 결과", size=14, bold=True, first=True)
para(tf, "비대칭: 짧게 틀리면 −7%, **길게 틀리면 −67%**. 적응 컨트롤러는 불필요 — "
         "오라클 이득 +1.6% < 탐색 비용.", size=12, color=GRAY)
para(tf, "TCP 공존 검증", size=14, bold=True, color=NAVY, space=2)
para(tf, "TCP+UDP 60G 동시에서 TCP 13.8 → **22.1 (+60%)**. L4 필터가 UDP 만 버리기 때문.", size=12, color=GRAY)

pic(s, "g2_loss_m9000.png", 4.35, y, 3.1)
tf = textbox(s, 7.8, y, 5.0, 4.6)
para(tf, "UDP 안에서는 무차별 — 지연 민감 흐름을 같이 잃는다", size=16, bold=True, color=RED, first=True)
para(tf, "프로브 손실   우리 **1~35%**   /   기존 UDP 0.00%   /   TCP 0.02%", size=13)
para(tf, "그래서 우리 p50/p99 는 **생존 편향**이 있다. 31% 를 버리고 남은 것의 p99 와 "
         "0.02% 만 버리고 잰 p99 는 같은 자가 아니다.", size=12, color=GRAY)
para(tf, "다만 fan-in 실험에서 새 정보:", size=14, bold=True, color=NAVY, space=2)
para(tf, "fan-in (소켓 1개)   1.1 ~ 8.3 %\nn:n     (소켓 n개)  17 ~ 34 %", size=12, font=MONO)
para(tf, "소켓이 하나면 autotune 이 충분히 키워 창이 거의 안 열린다. 소켓이 많으면 예산이 쪼개져 "
         "각 소켓이 작아지고 창이 상시 활성.", size=12, color=GRAY)
para(tf, "→ shed 단독의 결함이 아니라 **cap 과의 상호작용**이다.", size=13, bold=True, color=RED)
note(s, "M3 는 M2 를 대체할 수 없다:  8M × 8소켓은 shed 를 켜도 22.9 → **29.5** 에서 멈춘다 (1M+shed 는 55.8). "
        "캐시를 밀어내는 건 ‘일’이 아니라 ‘용량’이고, 용량은 cap 으로만 줄어든다.")

# ───────────────────────────── 12. M4 ─────────────────────────────
s = slide()
y = header(s, "M4. 드라이버 → 소켓 계층 ring 보고", "순정에는 이 경로가 아예 없다. M2 의 이식성이 여기에 달려 있다")
code(s, [
    "/* include/linux/netdevice.h:5657 */",
    "#define NET_RX_RING_ACTIVE_MS   1000",
    "int  net_rx_ring_register(long bytes);",
    "void net_rx_ring_unregister(int slot);",
    "void net_rx_ring_active(int slot);",
    "long net_rx_ring_bytes(void);",
    "",
    "/* mlx5/en_main.c — entry ≠ byte 환산은 드라이버만 할 수 있다 */",
    "static long mlx5e_rq_cache_bytes(struct mlx5e_rq *rq) {",
    "    if (rq->wq_type == MLX5_WQ_TYPE_LINKED_LIST_STRIDING_RQ)",
    ">       return mlx5_wq_ll_get_size(&rq->mpwqe.wq) *",
    ">              rq->mpwqe.pages_per_wqe * PAGE_SIZE;",
    "    ...",
    "}",
], 0.55, y, 7.3, 3.0, size=11)

table(s, [
    ["ethtool -g 표시", "순진한 계산 (×4KB)", "**실제**"],
    ["128", "0.5 MB", "**2 MB**"],
    ["1024 (드라이버 기본)", "4 MB", "**16 MB**"],
], 0.55, y + 3.2, 7.3, 1.2, size=13, colw=[2.5, 2.3, 2.0])
tf = textbox(s, 0.55, y + 4.55, 7.3, 0.7)
para(tf, "‘1024’ 를 본 관리자가 그게 L3 18MB 중 16MB 라는 걸 알 방법이 없다. 그리고 그게 −11 Gbps 다.",
     size=13, color=GRAY, first=True)

tf = textbox(s, 8.15, y, 4.7, 5.0)
para(tf, "★ v19 참사 — ‘활성’이 왜 필요한가", size=16, bold=True, color=RED, first=True)
para(tf, "처음엔 할당된 ring 을 전부 셌다. mlx5 기본이 combined 24:", size=13)
para(tf, "24 × 16MB = 384MB  ≫  L3 18MB\n→ 예산 0 → 어떤 소켓도 못 자람\n→ **4.35 Gb/s**,  ss 의 rb 가 **13**", size=12, font=MONO)
para(tf, "처리량만 봤으면 ‘autotune 이 좀 나쁘네’로 읽었을 것.", size=12, color=GRAY)
para(tf, "v20 수정", size=15, bold=True, color=NAVY, space=2)
para(tf, "poll 할 때 슬롯에 jiffies 를 찍고, **읽을 때** 최근 1초 활동분만 합산. "
         "감쇠가 읽기 시점이어야 하는 이유: 조용해진 ring 은 poll 이 안 돌아 **자기 침묵을 스스로 알릴 수 없다**.", size=12, color=GRAY)
para(tf, "할당은 정적이지만 캐시 압력은 트래픽이 도는 큐에서만 나온다.", size=13, bold=True, color=NAVY)

# ───────────────────────────── 13. sysctl / 방법론 ─────────────────────────────
s = slide()
y = header(s, "sysctl 표면 — 전부 default 0", "knob 을 끄면 동작상 upstream 과 동일하다")
table(s, [
    ["knob", "기본", "무엇", "비고"],
    ["net.ipv4.udp_rmem_autotune", "0", "M1 sizing", "0/1"],
    ["net.ipv4.udp_rmem_cache_pct", "0", "M2 전역 캐시 예산", "0=끔, **50 권장**"],
    ["net.ipv4.udp_rx_shed", "0", "M3 드라이버 조기 폐기", "0/1"],
    ["net.ipv4.udp_rx_shed_us", "50", "shed 창 길이", "스윕으로 고정"],
    ["net.ipv4.udp_rmem", "—", "min default max 삼중값", "tcp_rmem 대응"],
], 0.55, y, 8.6, 2.7, size=13, colw=[3.2, 0.8, 2.8, 1.8])

tf = textbox(s, 0.55, y + 2.9, 12.25, 2.3)
para(tf, "그래서 receiver 에 vanilla 를 따로 빌드할 필요가 없다.", size=20, bold=True, color=NAVY, first=True)
para(tf, "**같은 부팅에서 baseline / 실험군 A/B** 가 된다 → 커널 config 차이라는 confound 가 원천적으로 없다.", size=16)
para(tf, "", size=4)
para(tf, "코드에서 찾기:      grep -rn \"UDP-optimize\" <kernel-tree>", size=15, font=MONO)
para(tf, "net/ipv4/udp.c (M1 sizing, M2 cap+sweep, M3 mark)   ·   include/linux/udp.h (소켓별 상태 4개)   ·   "
         "include/linux/netdevice.h + net/core/dev.c (M4)   ·   mlx5/en_main.c + en_rx.c (ring 보고, shed 판정)",
     size=13, color=GRAY)

# ───────────────────────────── 14. 한계 ─────────────────────────────
s = slide()
y = header(s, "한계 — 정직하게", accent=RED)
tf = textbox(s, 0.55, y, 6.0, 5.2)
para(tf, "1. 폐기가 무차별 (가장 큰 미해결)", size=16, bold=True, color=RED, first=True)
para(tf, "프로브 손실 최대 35%. 지연 수치를 액면가로 쓰면 안 된다. 드라이버 시점은 소켓 조회 전이라 "
         "5-tuple 해시밖에 못 본다.", size=13, color=GRAY)
para(tf, "2. MTU 1500 에서는 TCP 에 진다", size=16, bold=True, color=RED, space=2)
para(tf, "×0.73~0.84. per-packet 비용이 지배하고 **버퍼 크기는 그 비용에 지렛대가 없다**. "
         "우리가 고친 건 ‘담을 데’지 ‘패킷당 일’이 아니다.", size=13, color=GRAY)
para(tf, "3. 부하만 줄면 축소가 안 될 수 있다", size=16, bold=True, color=RED, space=2)
para(tf, "버퍼가 부하보다 훨씬 커지면 주기가 완성되지 않아 target 이 얼어붙는다. "
         "유휴 회수 워커가 덮지만 그건 **경쟁이 있을 때만** arm 된다.", size=13, color=GRAY)

tf = textbox(s, 6.85, y, 6.0, 5.2)
para(tf, "4. 예산식이 실측이 아니다", size=16, bold=True, color=RED, first=True)
para(tf, "L3 − ring 은 **상한**이다. 아직 안 쓴 ring 페이지는 L3 에 없다. "
         "Intel CMT(llc_occupancy)로 직접 잴 수 있고, 아직 안 했다.", size=13, color=GRAY)
para(tf, "5. 큐가 많을 때 미검증", size=16, bold=True, color=RED, space=2)
para(tf, "모든 측정이 단일코어(큐 1개). 드라이버 기본은 24개. "
         "1코어가 55G 라 2코어면 100G 링크가 먼저 포화해 이 하드웨어에서는 측정 자체가 불가.", size=13, color=GRAY)
para(tf, "6. NIC 하나, 캐시 토폴로지 하나", size=16, bold=True, color=RED, space=2)
para(tf, "ConnectX-5 / Ice Lake-SP 18MB L3. 다른 하드웨어 미검증. "
         "드라이버 변경이 필요하다 (shed 와 ring 보고 둘 다 mlx5 패치).", size=13, color=GRAY)
para(tf, "7. 범위 밖 (후순위 엣지케이스)", size=16, bold=True, color=RED, space=2)
para(tf, "DIM off / 앱이 UDP_GRO 미설정.", size=13, color=GRAY)

# ───────────────────────────── 15. 마무리 ─────────────────────────────
s = slide()
bg = s.shapes.add_shape(1, 0, 0, W, prs.slide_height)
bg.fill.solid(); bg.fill.fore_color.rgb = NAVY; bg.line.fill.background()
tf = textbox(s, 1.0, 1.6, 11.3, 4.5)
para(tf, "한 문장으로", size=22, color=RGBColor(0x9F, 0xBA, 0xCA), first=True)
para(tf, "“rmem 을 N MB 로 맞춰라”가 아니라", size=26, color=RGBColor(0xBF, 0xD4, 0xE0), space=10)
para(tf, "수신 버퍼 상한은 메모리가 아니라", size=34, color=WHITE, bold=True, space=2)
para(tf, "producer/consumer 가 공유하는 캐시에서", size=34, color=WHITE, bold=True, space=2)
para(tf, "유도되어야 한다", size=34, color=WHITE, bold=True, space=20)
para(tf, "N 은 DIM 이 방금 무엇을 골랐는지에 달려 있고, 앱은 그걸 볼 수 없다.",
     size=16, color=RGBColor(0xBF, 0xD4, 0xE0))

prs.save(OUT)
print("saved:", OUT, os.path.getsize(OUT), "bytes,", len(prs.slides.__iter__.__self__._sldIdLst), "slides")
