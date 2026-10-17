"""CuePad 自家的图标（墨块）：从几何直接生成自定义 SF Symbol（模板 7.0，Ultralight / Regular / Black 三个母版插值），
整个重写 App 资源目录的 Symbols 下（两端共用，资源名 cue.<名>），并生成 LoopLayer 取用的"话在路上"三块 V 的路径（`ClimbBlocks.swift`）。
用法：python3 design/tools/cue-symbols.py（只用标准库）。

墨块的规则（每个图标都守）：
- 主体是实心的体块，细节是刻进去的缝与孔，不描边。外形圆、刀口直：剪影的拐角与自由端是圆的，刻进体块的缝是直的、利的。
- 体块之间、点睛与它的槽之间都隔一条刻缝（`CARVE`），层与层不重叠：单色下（系统菜单、工具栏里所有层同色）缝还在，认得出。生成时逐个检查，窄了就报错。
- 最多一块点睛，放在第二层（hierarchical 的 secondary，调色板渲染的第二个颜色）。点睛平时什么颜色、什么时候点亮是 App 代码里的着色规则，符号只管分层。
  点睛只能是小部件（一处点、一条缝里的块，不超过整个图形墨量的 `ACCENT_SHARE`，按 Regular 量、生成时检查——细的母版里主体墨少，占比自然高）：主体在主层——点睛平时是次一级的颜色，
  主体放进点睛层的话，没选中时整个图标是灰的，像被禁用。没有合适的小部件就不设点睛。
- 字重：体块按母版外扩 / 内缩（`GROW`），孔跟着缩 / 扩，缝在粗的母版里收窄一点——重量来自墨，不来自线。
- 品牌的物件：纸（圆角方纸 + 右上折角）、C 环（logo 的粗 C）、Cue（纸身体 + 斜着的腰环 + 竖着的眼）。

坐标：24 格，原点在图形中心、y 向下；1 格 = G 个模板单位，半径 12 格的圆 = 系统的 circle。图形中心落在大写字母高度的中线上，所以与文字基线对齐、随字号缩放。
同一个符号的三个母版轮廓命令序列必须逐条一致才能插值（写出前断言）：几何按字重变的只能是位置，不能是拐角、分段的有无。
"""
from __future__ import annotations

import math
import shutil
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "apple/App/Sources/Assets.xcassets/Symbols"
CLIMB_SWIFT = ROOT / "apple/App/Sources/UI/Shared/Theme/ClimbBlocks.swift"
PREFIX = "cue"

G = 35.6 / 12  # 一格的模板单位（系统 circle 在 S 号 100pt 下中线半径 35.6）
WEIGHTS = ("Ultralight", "Regular", "Black")
GROW = {"Ultralight": -0.9, "Regular": 0.0, "Black": 0.85}  # 体块外扩多少格
CARVE = {"Ultralight": 1.4, "Regular": 1.15, "Black": 0.9}  # 刻缝多宽（格）
ACCENT_SHARE = 0.2  # 点睛最多占整个图形墨量的多少
MID = 70.459 / 2  # 大写字母高度的一半：图形中心落在这条线上
BEARING = 7.0  # 两侧留白（系统符号实测）
BASELINE = 696.0
COLUMNS = {"Ultralight": 559.0, "Regular": 1391.0, "Black": 2224.0}


# ---------- 几何内核：直线、圆弧、三次曲线组成的闭合轮廓（模板单位） ----------
def add(p, q): return (p[0] + q[0], p[1] + q[1])
def sub(p, q): return (p[0] - q[0], p[1] - q[1])
def mul(p, k): return (p[0] * k, p[1] * k)
def dist(p, q): return math.hypot(p[0] - q[0], p[1] - q[1])
def norm(v): n = math.hypot(*v); return (v[0] / n, v[1] / n)
def left(t): return (t[1], -t[0])  # 行进方向的左侧（y 向下）
def cross(u, v): return u[0] * v[1] - u[1] * v[0]
def ang(v): return math.atan2(v[1], v[0])
def rot(p, deg): a = math.radians(deg); return (p[0] * math.cos(a) - p[1] * math.sin(a), p[0] * math.sin(a) + p[1] * math.cos(a))


@dataclass
class Line:
    a: tuple
    b: tuple
    def start(self): return self.a
    def end(self): return self.b
    def dir0(self): return norm(sub(self.b, self.a))
    def dir1(self): return self.dir0()


@dataclass
class Arc:
    c: tuple
    r: float
    a0: float
    sweep: float  # 弧度；y 向下，sweep > 0 在屏幕上是顺时针
    pieces: int = 0  # 写成几段三次曲线；0 是每段不超过 90°。圆角固定 1 段：段数不能跟着张角变，否则三个母版不能插值
    def pt(self, a): return (self.c[0] + self.r * math.cos(a), self.c[1] + self.r * math.sin(a))
    def start(self): return self.pt(self.a0)
    def end(self): return self.pt(self.a0 + self.sweep)
    def tan(self, a): s = 1 if self.sweep > 0 else -1; return (-math.sin(a) * s, math.cos(a) * s)
    def dir0(self): return self.tan(self.a0)
    def dir1(self): return self.tan(self.a0 + self.sweep)


@dataclass
class Cubic:
    p0: tuple
    p1: tuple
    p2: tuple
    p3: tuple
    def start(self): return self.p0
    def end(self): return self.p3
    def at(self, t):
        u = 1 - t
        return tuple(u ** 3 * self.p0[k] + 3 * u * u * t * self.p1[k] + 3 * u * t * t * self.p2[k] + t ** 3 * self.p3[k] for k in range(2))


def sample(s, t):
    if isinstance(s, Line): return add(s.a, mul(sub(s.b, s.a), t))
    if isinstance(s, Cubic): return s.at(t)
    return s.pt(s.a0 + s.sweep * t)


def reverse(s):
    if isinstance(s, Line): return Line(s.b, s.a)
    if isinstance(s, Cubic): return Cubic(s.p3, s.p2, s.p1, s.p0)
    return Arc(s.c, s.r, s.a0 + s.sweep, -s.sweep, s.pieces)


def rev(segs): return [reverse(s) for s in reversed(segs)]


def area(segs):
    pts = [sample(s, k / 8) for s in segs for k in range(8)]
    return sum(cross(pts[i], pts[(i + 1) % len(pts)]) for i in range(len(pts))) / 2


def poly(points, radius=0.0, closed=False):
    """折线（格）→ 段列表；拐角给圆角半径（格，可每个拐角一个），0 是利角。"""
    pts = [mul(p, G) for p in points]
    n = len(pts)
    radii = [r * G for r in (radius if isinstance(radius, list) else [radius] * n)]
    corners = range(n) if closed else range(1, n - 1)
    cut = {}
    for i in corners:
        r = radii[i]
        if r <= 0: continue
        A, B, C = pts[i - 1], pts[i], pts[(i + 1) % n]
        u, v = norm(sub(A, B)), norm(sub(C, B))
        theta = math.acos(max(-1, min(1, u[0] * v[0] + u[1] * v[1])))
        d = r / math.tan(theta / 2)
        c = add(B, mul(norm(add(u, v)), r / math.sin(theta / 2)))
        T1, T2 = add(B, mul(u, d)), add(B, mul(v, d))
        a0, a1 = ang(sub(T1, c)), ang(sub(T2, c))
        cut[i] = (T1, T2, Arc(c, r, a0, (a1 - a0 + math.pi) % (2 * math.pi) - math.pi, 1))
    segs = []
    order = list(range(n)) + ([0] if closed else [])
    prev = cut[0][1] if closed and 0 in cut else pts[0]
    for k in range(1, len(order)):
        i = order[k]
        segs.append(Line(prev, cut[i][0] if i in cut else pts[i]))
        if i in cut and (closed or k < len(order) - 1):
            segs.append(cut[i][2]); prev = cut[i][1]
        else:
            prev = pts[i]
    return segs


def arcs(c, r, deg0, sweep_deg):
    """一段圆弧（格）按不超过 90° 切开。"""
    n = max(1, math.ceil(abs(sweep_deg) / 90 - 1e-9))
    return [Arc(mul(c, G), r * G, math.radians(deg0 + sweep_deg * i / n), math.radians(sweep_deg / n)) for i in range(n)]


def catmull(points, closed=False):
    """过这些点的平滑三次曲线：段数只随点数，不随母版变。"""
    n, segs = len(points), []
    for i in range(n if closed else n - 1):
        p0 = points[(i - 1) % n] if (closed or i > 0) else points[0]
        p1, p2 = points[i], points[(i + 1) % n]
        p3 = points[(i + 2) % n] if (closed or i + 2 < n) else points[-1]
        segs.append(Cubic(p1, add(p1, mul(sub(p2, p0), 1 / 6)), sub(p2, mul(sub(p3, p1), 1 / 6)), p2))
    return segs


# ---- 圆头的一笔（勾、腰环、把手这类体块）：中线两侧偏移，外侧拐角补圆弧、内侧取交点 ----
def _offset(s, h):
    if isinstance(s, Line):
        n = mul(left(s.dir0()), h)
        return Line(add(s.a, n), add(s.b, n))
    r = s.r + h * (1 if s.sweep > 0 else -1)
    assert r > 0.01, f"弧的内侧半径塌了（r={s.r:.2f}, h={h:.2f}）"
    return Arc(s.c, r, s.a0, s.sweep, s.pieces)


def _meet(s1, s2, near):
    if isinstance(s1, Line) and isinstance(s2, Line):
        d1, d2 = sub(s1.b, s1.a), sub(s2.b, s2.a)
        den = cross(d1, d2)
        return s1.b if abs(den) < 1e-9 else add(s1.a, mul(d1, cross(sub(s2.a, s1.a), d2) / den))
    line, circ = (s1, s2) if isinstance(s1, Line) else (s2, s1)
    d = norm(sub(line.b, line.a)); f = sub(line.a, circ.c)
    b = f[0] * d[0] + f[1] * d[1]; c = f[0] ** 2 + f[1] ** 2 - circ.r ** 2
    disc_ = math.sqrt(max(0.0, b * b - c))
    return min((add(line.a, mul(d, -b + s * disc_)) for s in (-1, 1)), key=lambda q: dist(q, near))


def _trim_end(s, p):
    if isinstance(s, Line): return Line(s.a, p)
    sw = ang(sub(p, s.c)) - s.a0
    while sw - s.sweep > math.pi: sw -= 2 * math.pi
    while sw - s.sweep < -math.pi: sw += 2 * math.pi
    return Arc(s.c, s.r, s.a0, sw, s.pieces)


def _trim_start(s, p):
    if isinstance(s, Line): return Line(p, s.b)
    a0 = ang(sub(p, s.c)); sw = s.a0 + s.sweep - a0
    while sw - s.sweep > math.pi: sw -= 2 * math.pi
    while sw - s.sweep < -math.pi: sw += 2 * math.pi
    return Arc(s.c, s.r, a0, sw, s.pieces)


def _side(segs, h):
    offs = [_offset(s, h) for s in segs]
    joins = {}
    for i in range(len(segs) - 1):
        t0, t1 = segs[i].dir1(), segs[i + 1].dir0()
        turn = cross(t0, t1)
        if abs(turn) < 1e-6 and t0[0] * t1[0] + t0[1] * t1[1] > 0: continue
        joins[i] = (turn > 0) == (h > 0)  # 左侧在右转时是外侧
    for i, outer in joins.items():
        if not outer:
            p = _meet(offs[i], offs[i + 1], segs[i].end())
            offs[i], offs[i + 1] = _trim_end(offs[i], p), _trim_start(offs[i + 1], p)
    out = []
    for i, o in enumerate(offs):
        out.append(o)
        if joins.get(i):
            V = segs[i].end()
            a0, a1 = ang(sub(o.end(), V)), ang(sub(offs[i + 1].start(), V))
            out.append(Arc(V, abs(h), a0, (a1 - a0 + math.pi) % (2 * math.pi) - math.pi))
    return out


def stroke(segs, width):
    """开放中线（段列表）描成圆头的实心轮廓，顺时针。"""
    h = width / 2
    L, R = _side(segs, h), _side(segs, -h)
    P1, P0 = segs[-1].end(), segs[0].start()
    end_cap = Arc(P1, h, ang(left(segs[-1].dir1())), math.pi)
    start_cap = Arc(P0, h, ang(left(segs[0].dir0())) + math.pi, math.pi)
    c = L + [end_cap] + rev(R) + [start_cap]
    return c if area(c) > 0 else rev(c)


# ---------- 形（格） ----------
def rpoly(points, radii):
    """闭合多边形，每个拐角一个圆角半径（0 是利角），顺时针。"""
    segs = poly(points, radii, closed=True)
    return segs if area(segs) > 0 else rev(segs)


def grown(points, radii, g):
    """多边形（顺时针）每条边向外平移 g 格（斜接），圆角半径跟着加 g，利角保持利角。"""
    n, out = len(points), []
    for i in range(n):
        A, B, C = points[i - 1], points[i], points[(i + 1) % n]
        u, v = norm(sub(B, A)), norm(sub(C, B))
        nu, nv = (u[1], -u[0]), (v[1], -v[0])  # 顺时针（y 向下）多边形的外法线
        bis = norm(add(nu, nv))
        out.append(add(B, mul(bis, g / max(1e-6, bis[0] * nu[0] + bis[1] * nu[1]))))
    return rpoly(out, [max(0.15, r + g) if r else 0 for r in radii])


def disc(c, r, hole=False):
    segs = arcs(c, r, -90, 360)
    return rev(segs) if hole else segs


def ellipse(c, rx, ry):
    cx, cy = mul(c, G); rx, ry = rx * G, ry * G; k = 0.5523
    pts = [(cx + rx, cy), (cx, cy + ry), (cx - rx, cy), (cx, cy - ry)]
    ctl = [((cx + rx, cy + k * ry), (cx + k * rx, cy + ry)), ((cx - k * rx, cy + ry), (cx - rx, cy + k * ry)),
           ((cx - rx, cy - k * ry), (cx - k * rx, cy - ry)), ((cx + k * rx, cy - ry), (cx + rx, cy - k * ry))]
    return [Cubic(pts[i], ctl[i][0], ctl[i][1], pts[(i + 1) % 4]) for i in range(4)]


def bar(points, width, radius=0.0):
    """圆头的一笔（格）：造勾、腰环、把手这类实心块，宽度按体块算，不是描边。"""
    return stroke(poly(points, radius), width * G)


def bow(c, r, deg0, sweep, width):
    """圆头的一段粗弧（格）。"""
    return stroke(arcs(c, r, deg0, sweep), width * G)


def thick(pts, width, n=8):
    """一条采样中线（模板单位）描成等宽、圆头的实心，两侧各拟合成 n 段三次曲线：腰环这类曲线体块。"""
    h = width / 2
    idx = [round(k * (len(pts) - 1) / n) for k in range(n + 1)]
    def nrm(i): return left(norm(sub(pts[min(i + 1, len(pts) - 1)], pts[max(i - 1, 0)])))
    L = [add(pts[i], mul(nrm(i), h)) for i in idx]
    R = [sub(pts[i], mul(nrm(i), h)) for i in idx]
    c = catmull(L) + [Arc(pts[-1], h, ang(sub(L[-1], pts[-1])), math.pi)] + rev(catmull(R)) + [Arc(pts[0], h, ang(sub(R[0], pts[0])), math.pi)]
    return c if area(c) > 0 else rev(c)


def holed(cs): return [rev(c) for c in cs]


# ---- 裁切：闭合轮廓按"切刀"留下 f > 0 的一侧，切口是切刀自己的边（利角）；假设切出来是一整块 ----
class Along:
    """沿一条曲线（中线采样点，模板单位）的一侧：到曲线的有向距离减 off；side=+1 留行进方向左侧。切口是曲线的等距线。"""
    def __init__(self, pts, off, side=1, n=4):
        self.pts, self.off, self.side, self.n = pts, off, side, n

    def project(self, x):
        best = None
        for i in range(len(self.pts) - 1):
            a, b = self.pts[i], self.pts[i + 1]
            d = sub(b, a)
            t = max(0, min(1, ((x[0] - a[0]) * d[0] + (x[1] - a[1]) * d[1]) / (d[0] ** 2 + d[1] ** 2)))
            dd = dist(x, add(a, mul(d, t)))
            if best is None or dd < best[0]:
                best = (dd, i + t, 1 if cross(d, sub(x, a)) < 0 else -1)
        return best

    def f(self, x):
        dd, _, sgn = self.project(x)
        return (sgn * dd - self.off) * self.side

    def point(self, u):
        i = min(int(u), len(self.pts) - 2); t = u - i
        a, b = self.pts[i], self.pts[i + 1]
        return add(add(a, mul(sub(b, a), t)), mul(left(norm(sub(b, a))), self.off))

    def edge(self, E, N):
        u0, u1 = self.project(E)[1], self.project(N)[1]
        return catmull([E] + [self.point(u0 + (u1 - u0) * k / self.n) for k in range(1, self.n)] + [N])


def clip(contour, cut):
    def roots(s, n=64):
        vals = [cut.f(sample(s, k / n)) for k in range(n + 1)]
        out = []
        for k in range(n):
            if vals[k] * vals[k + 1] < 0:
                lo, hi = k / n, (k + 1) / n
                for _ in range(40):
                    mid = (lo + hi) / 2
                    if cut.f(sample(s, lo)) * cut.f(sample(s, mid)) <= 0: hi = mid
                    else: lo = mid
                out.append((lo + hi) / 2)
        return out

    def piece(s, t0, t1):
        if isinstance(s, Line): return Line(sample(s, t0), sample(s, t1))
        assert isinstance(s, Arc), "裁切的轮廓只支持直线与圆弧"
        return Arc(s.c, s.r, s.a0 + s.sweep * t0, s.sweep * (t1 - t0), 1)

    parts = []
    for s in contour:
        ts = [0.0] + roots(s) + [1.0]
        for t0, t1 in zip(ts, ts[1:]):
            p = piece(s, t0, t1)
            parts.append((p, cut.f(sample(p, 0.5)) > 0))
    if all(inside for _, inside in parts): return contour
    start = next(i for i in range(len(parts)) if parts[i][1] and not parts[i - 1][1])
    parts = parts[start:] + parts[:start]
    out, i = [], 0
    while i < len(parts):
        if parts[i][1]:
            out.append(parts[i][0]); i += 1; continue
        while i < len(parts) and not parts[i][1]: i += 1
        out += cut.edge(out[-1].end(), parts[i][0].start() if i < len(parts) else out[0].start())
    return out


@dataclass
class Layer:
    name: str
    contours: list
    tier: str = "primary"  # secondary 是点睛


# ---------- 图标：每个函数（母版名）→ [Layer]，第一层是墨，第二层（有的话）是点睛 ----------
def mascot(eyes="open"):
    """Cue：纸身体（右上让出折角的槽）、斜着的腰环（前半圈压在身体上，把身体切成上下两块）、折角是点睛。
    四种眼睛用同一种笔画（三点、两段、同向微折）挖出来，结构一致：竖胶囊（醒）、往右挪的竖胶囊（看向一边）、横缝（睡）、^（开心）。"""
    def build(m):
        g, c = GROW[m], CARVE[m]
        x0, x1, y0, y1, r, e = -8.0 - g, 8.0 + g, -11.2 - g, 10.6 + g, 4.4 + g, 4.1 + g * 0.5
        body = rpoly([(x0, y0), (x1 - e - c, y0), (x1 - e - c, y0 + e + c), (x1, y0 + e + c), (x1, y1), (x0, y1)],
                     [r, 0.5 + g * 0.5, 0, 0.5 + g * 0.5, r, r])
        # 腰环是一个剪切过的椭圆：前半圈压在身体上，两头绕到身体两侧外面再往身后收，在离身体一条刻缝处收住
        t = 3.0 + 1.0 * g
        A, B, cy, sh = 11.4 + g, 3.4, 2.6, -0.2
        def E(th): return mul((A * math.cos(th), cy + B * math.sin(th) + sh * A * math.cos(th)), G)
        front = [E(math.pi - math.pi * k / 120) for k in range(121)]
        upper = clip(body, Along(front, t * G / 2 + c * G, 1))
        lower = clip(body, Along(front, -(t * G / 2 + c * G), -1))
        edge = (8.0 + g + c + t / 2) / A
        th0, th1 = math.pi + math.acos(edge), 2 * math.pi - math.acos(edge)
        ring = thick([E(th0 - (th0 - (th1 - 2 * math.pi)) * k / 160) for k in range(161)], t * G, 10)
        ex, ey = 3.0, -1.8
        erx, ery = 1.5 - g * 0.15, 2.4 - g * 0.15
        def eye(x, y, kind):
            if kind == "pill": return bar([(x + 0.03, y - ery + erx), (x, y), (x + 0.03, y + ery - erx)], 2 * erx)
            if kind == "shut": return bar([(x - 1.5, y + 1.0), (x, y + 1.05), (x + 1.5, y + 1.0)], 1.45 - g * 0.15)
            return bar([(x + 1.6, y + 1.0), (x, y - 0.5), (x - 1.6, y + 1.0)], 1.5 - g * 0.15)
        kind, dx = {"open": ("pill", 0), "look": ("pill", 1.4), "sleep": ("shut", 0), "happy": ("smile", 0)}[eyes]
        face = holed([eye(-ex + dx, ey, kind), eye(ex + dx, ey, kind)])
        ear = rpoly([(x1 - e, y0), (x1, y0 + e), (x1 - e, y0 + e)], [0.7 + g * 0.4, 0.7 + g * 0.4, 0])
        return [Layer("body", [upper] + face + [lower]), Layer("ring", [ring]), Layer("ear", [ear], "secondary")]
    return build


def idea(m):
    """灵感：灯泡。泡（圆头接收窄的颈）与灯座一块墨，中间一道平刀口；泡里挖一道弯槽，嵌着一弯灯丝（点睛）——点亮就是有了灵感。"""
    g, c = GROW[m], CARVE[m]
    neck = grown([(-4.8, -0.8), (4.8, -0.8), (3.6, 5.0), (-3.6, 5.0)], [0, 0, 0.6, 0.6], g)
    head = disc((0, -3.8), 7.9 + g)
    base = grown([(-3.6, 5.0 + c + 2 * g), (3.6, 5.0 + c + 2 * g), (3.6, 10.2), (-3.6, 10.2)], [0, 0, 1.7, 1.7], g)
    w = 1.5 + 0.5 * g
    def loop(width): return bow((0, -6.2), 2.4, 15, 150, width)
    return [Layer("bulb", [head, neck, rev(loop(w + 2 * c)), base]), Layer("filament", [loop(w)], "secondary")]


def task(m):
    """任务：三行清单。每行一截圆头的条；行首第一行是勾（点睛），另两行是小方块。"""
    g, c = GROW[m], CARVE[m]
    rows = (-7.0, 0.0, 7.0)
    bars = [bar([(-0.8, y), (9.6, y)], 3.4 + 1.4 * g) for y in rows]
    boxes = [grown([(-10.2, y - 2.0), (-6.2, y - 2.0), (-6.2, y + 2.0), (-10.2, y + 2.0)], [0.9] * 4, g * 0.7) for y in rows[1:]]
    check = bar([(-10.6, -7.4), (-8.7, -5.2), (-5.4, -9.6)], 2.4 + 0.9 * g)
    return [Layer("list", bars + boxes), Layer("check", [check], "secondary")]


def session(m):
    """会话（Agent 在跑）：一截粗的心电波，波尾隔一道刻缝是一颗点（点睛，走在前面的那一下）。"""
    g, c = GROW[m], CARVE[m]
    w, r = 3.0 + 1.4 * g, 2.3 + 0.6 * g
    end = 5.6
    wave = bar([(-11.0, 0), (-6.2, 0), (-3.9, -6.6), (-0.2, 6.6), (2.4, -3.2), (3.8, 0), (end, 0)], w)
    dot = disc((end + w / 2 + c + r, 0), r)
    return [Layer("wave", [wave]), Layer("dot", [dot], "secondary")]


def search(look=1.1):
    """搜索：粗镜圈 + 一道刻缝隔开的实心把手；镜片里一只竖椭圆的眼（同 Cue 的眼，点睛）。look 是眼往右偏多少格。"""
    def build(m):
        g, c = GROW[m], CARVE[m]
        o, r, T = (-2.2, -2.2), 6.9, 3.9 + 1.6 * g
        ring = [disc(o, r + T / 2), disc(o, r - T / 2, hole=True)]
        s0 = (r + T / 2 + c + 0.4) * 0.7071
        handle = bar([(o[0] + s0 + 1.8, o[1] + s0 + 1.8), (9.4, 9.4)], 5.4 + 2 * g)
        eye = ellipse((o[0] + look, o[1] - 0.3), 1.5 + g * 0.1, 2.4 + g * 0.1)
        return [Layer("lens", ring + [handle]), Layer("eye", [eye], "secondary")]
    return build


def settings(m):
    """设置：六齿的实心齿轮（方头的齿），中间挖轴孔，孔里嵌一颗轴心（点睛）。"""
    g, c = GROW[m], CARVE[m]
    Ro, Ri = 11.2 + g, 8.0 + g
    pts, radii = [], []
    for k in range(6):
        for da, R, rr in ((-19, Ri, 1.2), (-13, Ro, 1.1 + g * 0.5), (13, Ro, 1.1 + g * 0.5), (19, Ri, 1.2)):
            a = math.radians(k * 60 - 90 + da); pts.append((R * math.cos(a), R * math.sin(a))); radii.append(rr)
    hr = 4.9 - g
    return [Layer("gear", [rpoly(pts, radii), disc((0, 0), hr, hole=True)]), Layer("axle", [disc((0, 0), hr - c - 0.3)], "secondary")]


def inbox(m):
    """未分类：一只托盘（上沿中间凹下去一块），上方一张小纸条（点睛）正落进去。"""
    g, c = GROW[m], CARVE[m]
    tray = grown([(-11, -1.2), (-5.2, -1.2), (-3.6, 2.0), (3.6, 2.0), (5.2, -1.2), (11, -1.2), (11, 8.4), (-11, 8.4)],
                 [0.8, 0.5, 0.6, 0.6, 0.5, 0.8, 2.8, 2.8], g)
    slip = grown([(-3.2, -8.6), (3.2, -8.6), (3.2, -1.2 - c - 2 * g), (-3.2, -1.2 - c - 2 * g)], [1.0, 1.0, 0, 0], g)
    return [Layer("tray", [tray]), Layer("slip", [slip], "secondary")]


def archive(m):
    """归档：箱盖一块、箱身一块，中间一道平刀口；箱身上挖一道把手槽。"""
    g, c = GROW[m], CARVE[m]
    lid = grown([(-11, -9.6), (11, -9.6), (11, -4.8), (-11, -4.8)], [1.4, 1.4, 0.5, 0.5], g)
    body = grown([(-9.6, -4.8 + c + 2 * g), (9.6, -4.8 + c + 2 * g), (9.6, 9.8), (-9.6, 9.8)], [0, 0, 2.6, 2.6], g)
    slot = rev(bar([(-3.0, -0.4), (3.0, -0.4)], 2.0 - 0.5 * g))
    return [Layer("box", [lid, body, slot])]


def trash(m):
    """回收站：盖子（带提手）一块、桶身一块，中间一道平刀口；桶身上挖两道竖槽。"""
    g, c = GROW[m], CARVE[m]
    lid = grown([(-10.6, -8.8), (-3.4, -8.8), (-3.4, -11.4), (3.4, -11.4), (3.4, -8.8), (10.6, -8.8), (10.6, -5.6), (-10.6, -5.6)],
                [1.4, 0, 1.0, 1.0, 0, 1.4, 1.4, 1.4], g)
    top = -5.6 + c + 2 * g
    can = grown([(-8.8, top), (8.8, top), (7.2, 10.6), (-7.2, 10.6)], [0, 0, 2.4, 2.4], g)
    slots = holed([bar([(x, -0.8), (x, 6.0)], 1.9 - 0.5 * g) for x in (-2.7, 2.7)])
    return [Layer("can", [lid, can] + slots)]


def sidebar(m):
    """侧栏：一扇窗切成两块，左边窄的那块是侧栏，中间一道竖刀口。没有点睛（侧栏占了三分之一，不是小部件）。"""
    g, c = GROW[m], CARVE[m]
    y0, y1, split = -9.0, 9.0, -3.8
    panel = grown([(-11.2, y0), (split, y0), (split, y1), (-11.2, y1)], [2.8, 0, 0, 2.8], g)
    main = grown([(split + c + 2 * g, y0), (11.2, y0), (11.2, y1), (split + c + 2 * g, y1)], [0, 2.8, 2.8, 0], g)
    return [Layer("window", [main]), Layer("panel", [panel])]


def cross_shape(L, w, deg=0):
    """十字（格）：臂长 L、半宽 w，外角圆、内角利，转 deg 度。"""
    pts = [(-w, -L), (w, -L), (w, -w), (L, -w), (L, w), (w, w), (w, L), (-w, L), (-w, w), (-L, w), (-L, -w), (-w, -w)]
    radii = [w * 0.9, w * 0.9, 0] * 4
    return rpoly([rot(p, deg) for p in pts], radii)


def plus(m):
    """新建：实心十字。"""
    g = GROW[m]
    return [Layer("plus", [cross_shape(9.8 + g * 0.5, 2.1 + g)])]


def close(m):
    """关闭：十字转 45°。"""
    g = GROW[m]
    return [Layer("close", [cross_shape(10.4 + g * 0.5, 2.0 + g, 45)])]


def clear(m):
    """清除：实心圆墨，里面挖一个 ×。"""
    g = GROW[m]
    return [Layer("clear", [disc((0, 0), 11.0 + g), rev(cross_shape(6.4 - g * 0.3, 1.5 - g * 0.4, 45))])]


def more(m):
    """更多：三颗实心圆点。"""
    g = GROW[m]
    return [Layer("more", [disc((x, 0), 2.5 + 0.6 * g) for x in (-7.6, 0, 7.6)])]


def chevron(deg):
    """箭头（四向）：一块实心的 V（同"话在路上"的块：外沿尖、两端平切），一份几何转出四个方向；deg=0 朝上。"""
    def build(m):
        g = GROW[m] * 0.8
        half, drop, t = 7.4, 6.2, 3.6
        top = -(drop + t) / 2
        pts = [(0, top), (half, top + drop), (half, top + drop + t), (0, top + t), (-half, top + drop + t), (-half, top + drop)]
        return [Layer("chevron", [grown([rot(p, deg) for p in pts], [0.6, 0.5, 0.5, 0, 0.5, 0.5], g)])]
    return build


def send(m):
    """发送：一枚燕尾箭镞——高而尖，底边往里凹成 V；箭杆顶削成同角度的尖插在 V 里，中间一道等宽刀口。
    两块都在主层（箭镞比箭杆还大，不是小部件），分两层只为按层动效（箭杆、箭镞依次一跳）。
    先按 Regular 画，两块各自外扩 g：刀口预留 2g，外扩后正好是这一档的刻缝。"""
    g, c = GROW[m], CARVE[m]
    k, notch, bx = 0.75, -1.6, 7.6  # V 的斜率、谷底、两翼半宽
    cut = (c + 2 * g) / math.cos(math.atan(k))
    head = grown([(0, -12.0), (bx, notch + bx * k), (0, notch), (-bx, notch + bx * k)], [0.5, 0.45, 0, 0.45], g)
    w, top = 2.4, notch + cut
    shaft = grown([(0, top), (w, top + w * k), (w, 11.4), (-w, 11.4), (-w, top + w * k)], [0, 0, 1.0, 1.0, 0], g)
    return [Layer("shaft", [shaft]), Layer("head", [head])]


def stop(m):
    """停止：一块圆角方墨。"""
    g = GROW[m]
    h, r = 7.0 + g, 2.4 + g
    return [Layer("stop", [rpoly([(-h, -h), (h, -h), (h, h), (-h, h)], [r] * 4)])]


def done(stage="done"):
    """做完：C 环（logo 的 C，开口朝右上）里伸出一个勾；勾的拐点在圆心附近，最粗的母版里也离 C 一条刻缝。
    勾与 C 都在主层（勾是一整笔，不是小部件）；分两层只为按层动效。
    pre 是做完之前的那一下：勾缩成拐点处一颗点（同一种笔画、两臂几乎为零，结构与勾一致），动效里弹成勾。"""
    def build(m):
        g = GROW[m]
        T, tc = 4.2 + 1.2 * g, 3.3 + 1.0 * g
        v = (-1.4, 2.2)
        tick = bar([(v[0] - 0.03, v[1]), v, (v[0] + 0.03, v[1] - 0.001)], tc) if stage == "pre" else bar([(v[0] - 2.55, v[1] - 2.55), v, (10.6, -8.6)], tc)
        return [Layer("seal", [bow((-1.0, 0.8), 9.2, 4, 268, T)]), Layer("tick", [tick])]
    return build


# "话在路上"三块实心 V：外沿 V 的尖在 tip、两端降 DROP（斜率同发送的箭镞），竖厚 THICK，两端竖切；从下往上排。
# 22 格、y 朝下（LoopLayer 的画布），符号里减去中心 11。LoopLayer 的 climb 与符号 cue.climb 都只从这里来。
CLIMB_TIPS, CLIMB_HALF, CLIMB_DROP, CLIMB_THICK = (12.1, 6.9, 1.7), 6.8, 5.1, 3.2


def climb_block(tip):
    return [(11, tip), (11 + CLIMB_HALF, tip + CLIMB_DROP), (11 + CLIMB_HALF, tip + CLIMB_DROP + CLIMB_THICK),
            (11, tip + CLIMB_THICK), (11 - CLIMB_HALF, tip + CLIMB_DROP + CLIMB_THICK), (11 - CLIMB_HALF, tip + CLIMB_DROP)]


def climb(m):
    """话在路上（静止版，减弱动态效果与菜单里）：三块实心 V，与状态标里循环的 LoopLayer.climb 同形。字重只外扩四成 g，块间刀口不被吃掉。"""
    g = GROW[m] * 0.4
    return [Layer("climb", [grown([(x - 11, y - 11) for x, y in climb_block(tip)], [0] * 6, g) for tip in CLIMB_TIPS])]


SYMBOLS = {
    "mascot": mascot("open"),
    "mascot.sleep": mascot("sleep"),
    "mascot.look": mascot("look"),
    "mascot.happy": mascot("happy"),
    "idea": idea,
    "task": task,
    "session": session,
    "search": search(),
    "settings": settings,
    "inbox": inbox,
    "archive": archive,
    "trash": trash,
    "sidebar": sidebar,
    "plus": plus,
    "close": close,
    "clear": clear,
    "more": more,
    "chevron.up": chevron(0),
    "chevron.right": chevron(90),
    "chevron.down": chevron(180),
    "chevron.left": chevron(270),
    "send": send,
    "stop": stop,
    "done": done(),
    "done.pre": done("pre"),
    "climb": climb,
}


# ---------- 写出 ----------
def fmt(v): return f"{v:.3f}".rstrip("0").rstrip(".")


def d_of(contour, dx, dy):
    def P(p): return f"{fmt(p[0] + dx)},{fmt(p[1] + dy)}"
    out = [f"M{P(contour[0].start())}"]
    for s in contour:
        if isinstance(s, Line):
            out.append(f"L{P(s.b)}")
        elif isinstance(s, Cubic):
            out.append(f"C{P(s.p1)} {P(s.p2)} {P(s.p3)}")
        else:
            n = s.pieces or max(1, math.ceil(abs(s.sweep) / (math.pi / 2) - 1e-9))
            step = s.sweep / n
            k = 4 / 3 * math.tan(step / 4)
            for i in range(n):
                a, b = s.a0 + step * i, s.a0 + step * (i + 1)
                p0, p3 = s.pt(a), s.pt(b)
                c1 = add(p0, mul((-math.sin(a), math.cos(a)), k * s.r))
                c2 = sub(p3, mul((-math.sin(b), math.cos(b)), k * s.r))
                out.append(f"C{P(c1)} {P(c2)} {P(p3)}")
    out.append("Z")
    return " ".join(out)


def structure(layers):
    return ["".join(ch for ch in d_of(c, 0, 0) if ch in "MLCZ") for L in layers for c in L.contours]


def check_gaps(name, layers, m):
    """层与层之间最窄的缝不能比刻缝窄：单色下靠它分开。"""
    pts = [[sample(s, k / 24) for c in L.contours for s in c for k in range(24)] for L in layers]
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            d = min(dist(a, b) for a in pts[i] for b in pts[j]) / G
            assert d >= CARVE[m] * 0.9, f"{name} {m}：{layers[i].name} 与 {layers[j].name} 之间的缝只有 {d:.2f} 格（刻缝 {CARVE[m]}）"


def check_accent(name, layers):
    """点睛只能是小部件：主体放进点睛层，平时次一级的颜色下整个图标是灰的。"""
    ink = [abs(sum(area(c) for c in L.contours)) for L in layers]
    accent = sum(a for a, L in zip(ink, layers) if L.tier == "secondary")
    assert accent <= ACCENT_SHARE * sum(ink), f"{name}：点睛占了墨量的 {accent / sum(ink):.0%}（最多 {ACCENT_SHARE:.0%}），主体要在主层"


def template(per):
    """per：{母版: [Layer]}。"""
    s = {w: structure(per[w]) for w in WEIGHTS}
    assert len({str(v) for v in s.values()}) == 1, f"三个母版结构不一致：{ {w: len(v) for w, v in s.items()} }"
    line = 'style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
    guides = [f'<line id="Baseline-{s}" {line} x1="263" x2="3036" y1="{b}" y2="{b}"/>'
              f'<line id="Capline-{s}" {line} x1="263" x2="3036" y1="{b - 70.459:.3f}" y2="{b - 70.459:.3f}"/>'
              for s, b in (("S", 696), ("M", 1126), ("L", 1556))]
    groups = []
    tiers = [L.tier for L in per["Regular"]]
    for w in ("Black", "Regular", "Ultralight"):
        xs = [sample(sg, k / 32)[0] for L in per[w] for c in L.contours for sg in c for k in range(33)]
        width = max(xs) - min(xs) + 2 * BEARING
        left_ = COLUMNS[w] - width / 2
        dx = -min(xs) + BEARING
        guides.append(f'<line id="left-margin-{w}-S" {line} x1="{left_:.3f}" x2="{left_:.3f}" y1="600.785" y2="720.121"/>'
                      f'<line id="right-margin-{w}-S" {line} x1="{left_ + width:.3f}" x2="{left_ + width:.3f}" y1="600.785" y2="720.121"/>')
        paths = [f'<path class="monochrome-{i} multicolor-{i}:tintColor hierarchical-{i}:{tiers[i]} SFSymbolsPreviewWireframe" '
                 f'd="{" ".join(d_of(c, dx, -MID) for c in L.contours)}"/>' for i, L in enumerate(per[w])]
        groups.append(f'<g id="{w}-S" transform="matrix(1 0 0 1 {left_:.3f} {BASELINE})">{"".join(paths)}</g>')
    styles = [".defaults {-sfsymbols-variable-value-mode:color;-sfsymbols-draw-reverses-motion-groups:false}"]
    for i in range(len(tiers)):
        for prefix in (f"monochrome-{i}", f"multicolor-{i}:tintColor", f"hierarchical-{i}:{tiers[i]}"):
            styles.append(f".{prefix} {{-sfsymbols-motion-group:{i}}}")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3300 2200">\n'
            f'<style>{chr(10).join(styles)}\n.SFSymbolsPreviewWireframe {{fill:none;opacity:1.0;stroke:black;stroke-width:0.5}}</style>\n'
            '<g id="Notes"><rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>'
            '<text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" '
            'transform="matrix(1 0 0 1 3036 1933)">Template v.7.0</text></g>\n'
            f'<g id="Guides">{"".join(guides)}</g>\n'
            f'<g id="Symbols">{"".join(groups)}</g>\n</svg>\n')


INFO = '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'


def write_symbols():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    (OUT / "Contents.json").write_text(INFO)
    for name, build in SYMBOLS.items():
        per = {w: build(w) for w in WEIGHTS}
        for w in WEIGHTS: check_gaps(name, per[w], w)
        check_accent(name, per["Regular"])
        full = f"{PREFIX}.{name}"
        folder = OUT / f"{full}.symbolset"
        folder.mkdir()
        (folder / f"{full}.svg").write_text(template(per))
        (folder / "Contents.json").write_text(
            '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n'
            '  "properties" : {\n    "symbol-rendering-intent" : "template"\n  },\n  "symbols" : [\n    {\n'
            f'      "filename" : "{full}.svg",\n      "idiom" : "universal"\n    }}\n  ]\n}}\n')


def write_climb():
    blocks = ",\n".join("        [" + ", ".join(f"CGPoint(x: {fmt(x)}, y: {fmt(y)})" for x, y in climb_block(tip)) + "]" for tip in CLIMB_TIPS)
    CLIMB_SWIFT.write_text(
        "// 由 design/tools/cue-symbols.py 生成，改形状改那里（符号 cue.climb 出自同一份）。\n"
        "import CoreGraphics\n\n"
        '/// "话在路上"三块实心 V 的顶点：22 × 22、y 朝下的格子，从下往上排（`LoopLayer.climb` 画它）。\n'
        "enum ClimbBlocks {\n"
        f"    static let blocks: [[CGPoint]] = [\n{blocks},\n    ]\n"
        "}\n")


if __name__ == "__main__":
    write_symbols()
    write_climb()
