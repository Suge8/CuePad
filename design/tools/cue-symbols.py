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
    if not any(inside for _, inside in parts): return None
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
    ground: bool = False  # 反白符号的实心底（见 `picked`）：在第二层，但不是点睛，不受点睛占比限制


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


def send_parts(g, c, s=1.0):
    """燕尾箭镞与箭杆（格，朝上）：s 按比例缩放整支，刀口不随着缩，每档仍是一条刻缝。"""
    k, notch, bx = 0.75, -1.6 * s, 7.6 * s  # V 的斜率、谷底、两翼半宽
    cut = (c + 2 * g) / math.cos(math.atan(k))
    head = grown([(0, -12.0 * s), (bx, notch + bx * k), (0, notch), (-bx, notch + bx * k)], [0.5, 0.45, 0, 0.45], g)
    w, top = 2.4 * s, notch + cut
    shaft = grown([(0, top), (w, top + w * k), (w, 11.4 * s), (-w, 11.4 * s), (-w, top + w * k)], [0, 0, 1.0, 1.0, 0], g)
    return shaft, head


def send(m):
    """发送：一枚燕尾箭镞——高而尖，底边往里凹成 V；箭杆顶削成同角度的尖插在 V 里，中间一道等宽刀口。
    两块都在主层（箭镞比箭杆还大，不是小部件），分两层只为按层动效（箭杆、箭镞依次一跳）。
    先按 Regular 画，两块各自外扩 g：刀口预留 2g，外扩后正好是这一档的刻缝。
    箭头一族（在上面、拿回来的、更早的就用它；回到最新、压缩上下文按方向转）都是这一支。"""
    shaft, head = send_parts(GROW[m], CARVE[m])
    return [Layer("shaft", [shaft]), Layer("head", [head])]


def stop(m):
    """停止：一块圆角方墨。"""
    g = GROW[m]
    h, r = 7.0 + g, 2.4 + g
    return [Layer("stop", [rpoly([(-h, -h), (h, -h), (h, h), (-h, h)], [r] * 4)])]


DONE_TICK = [(-3.95, -0.35), (-1.4, 2.2), (10.6, -8.6)]  # 做完里那一笔勾的三个点（格）


def done(stage="done"):
    """做完：C 环（logo 的 C，开口朝右上）里伸出一个勾；勾的拐点在圆心附近，最粗的母版里也离 C 一条刻缝。
    勾与 C 都在主层（勾是一整笔，不是小部件）；分两层只为按层动效。
    pre 是做完之前的那一下：勾缩成拐点处一颗点（同一种笔画、两臂几乎为零，结构与勾一致），动效里弹成勾。"""
    def build(m):
        g = GROW[m]
        T, tc = 4.2 + 1.2 * g, 3.3 + 1.0 * g
        v = DONE_TICK[1]
        tick = bar([(v[0] - 0.03, v[1]), v, (v[0] + 0.03, v[1] - 0.001)], tc) if stage == "pre" else bar(DONE_TICK, tc)
        return [Layer("seal", [bow((-1.0, 0.8), 9.2, 4, 268, T)]), Layer("tick", [tick])]
    return build


# ---------- 状态（会话、同步、通知）：几个形状族各一份几何，换刻进去的记号或加一个角标出几个 ----------
# 记号（问号、叹号、勾、箭头……）是刻进体块的孔（`holed`）：状态图标整个按状态色画，记号是透出来的底，小字号也最清楚。
# 孔随字重收窄（`MARK_W`），体块随字重外扩：重量来自墨。孔是刻出来的，箭镞的角是利的。

def MARK_W(m, base=3.0): return base - 0.5 * GROW[m]


class Outside:
    """圆外一侧（裁切用）：到圆心的距离减 R（格）；切口是这个圆的一段，给角标让出一条刻缝。
    轮廓顺时针走，切口凹进体块，沿圆逆时针走（圆心在体块里时这一段超过半圈，不能取短的那段）。"""
    def __init__(self, c, R, n=8):
        self.c, self.R, self.n = mul(c, G), R * G, n

    def f(self, x): return dist(x, self.c) - self.R

    def edge(self, E, N):
        a0 = ang(sub(E, self.c)); sw = (ang(sub(N, self.c)) - a0) % (2 * math.pi) - 2 * math.pi
        return catmull([E] + [add(self.c, mul((math.cos(a0 + sw * k / self.n), math.sin(a0 + sw * k / self.n)), self.R)) for k in range(1, self.n)] + [N])


def arrow(segs, width, head):
    """一笔带箭镞（模板单位）：尾端圆头，头端是三角箭镞；head=(镞长, 镞半宽)。"""
    h, (hl, hw) = width / 2, head
    L, R = _side(segs, h), _side(segs, -h)
    P1, t, P0 = segs[-1].end(), segs[-1].dir1(), segs[0].start()
    n = left(t)
    a, tip, b = add(P1, mul(n, hw)), add(P1, mul(t, hl)), sub(P1, mul(n, hw))
    c = L + [Line(L[-1].end(), a), Line(a, tip), Line(tip, b), Line(b, R[-1].end())] + rev(R) + [Arc(P0, h, ang(left(segs[0].dir0())) + math.pi, math.pi)]
    return c if area(c) > 0 else rev(c)


def at(c, s, p): return (c[0] + p[0] * s, c[1] + p[1] * s)


def mark_question(c, s, w):
    hook = stroke([*arcs(at(c, s, (0, -3.0)), 3.4 * s, 195, 255), Line(mul(at(c, s, (0, 0.4)), G), mul(at(c, s, (0, 2.2)), G))], w * s * G)
    return [hook, disc(at(c, s, (0, 6.0)), 1.75 * s * w / 3.0)]


def mark_exclaim(c, s, w):
    return [bar([at(c, s, (0, -6.6)), at(c, s, (0, 1.8))], w * s), disc(at(c, s, (0, 6.0)), 1.8 * s * w / 3.0)]


def mark_tick(c, s, w):
    return [bar([at(c, s, (-5.6, 0.2)), at(c, s, (-1.8, 4.0)), at(c, s, (5.8, -4.4))], w * s)]


def mark_pause(c, s, w):
    return [bar([at(c, s, (x, -4.4)), at(c, s, (x, 4.4))], w * s) for x in (-2.7, 2.7)]


def mark_arrow(c, s, w, down=False):
    k = -1 if down else 1
    a, b = at(c, s, (0, 6.2 * k)), at(c, s, (0, -2.4 * k))
    return [arrow([Line(mul(a, G), mul(b, G))], w * s * G, (3.6 * s * G, 4.0 * s * G))]


def mark_uturn(c, s, w):
    """往回折的箭头（没能送达：话折回来了）：从左下往右、绕过右边折回上面，箭镞朝左。"""
    P = lambda p: mul(at(c, s, p), G)
    segs = [Line(P((-3.2, 5.0)), P((1.6, 5.0))), *[Arc(P((1.6, 1.0)), 4.0 * s * G, math.radians(90), math.radians(-180), 2)], Line(P((1.6, -3.0)), P((-2.6, -3.0)))]
    return [arrow(segs, w * s * G, (3.4 * s * G, 3.8 * s * G))]


def mark_cycle(c, s, w):
    """转一圈的箭头（同步中）：一段 270° 的弧，箭镞顺时针。"""
    return [arrow(arcs(c, 4.2 * s, 30, 250), w * s * G, (2.8 * s * G, 3.2 * s * G))]


def slash_cut(shape, m, w, k=0.0):
    """被一道左上到右下的斜杠劈开：两块各离斜杠一条刻缝，斜杠是自己一块（关掉、停掉、断了）。整块落在一侧的不切，原样留下。k 把斜杠往右上平移（格），
    躲开切口正好落在圆角与直边交界处的位置——那里三个母版会一个切在弧上、一个切在直边上，结构对不上。"""
    line = [mul((-16 + k, -16 - k), G), mul((16 + k, 16 - k), G)]
    off = (w / 2 + CARVE[m]) * G
    return [p for p in (clip(shape, Along(line, off, 1)), clip(shape, Along(line, -off, -1))) if p]


def slash(m, a=9.6, k=0.0):
    w = 2.6 + 1.2 * GROW[m]
    return w, bar([(-a * 0.7071 + k, -a * 0.7071 - k), (a * 0.7071 + k, a * 0.7071 - k)], w)


def badge(mark, solid=True):
    """圆标：实心圆里刻出记号（要你看的：等你、出错、没能送达，与选上），或一圈圆环、记号自己一块嵌在里面（不急的：未知）。
    实心圆同系统的 circle.fill 一样大（半径 12.6 格，比线条的圆大一圈）：放进同一行字里，与系统符号一般高。"""
    def build(m):
        g = GROW[m]
        if solid:
            return [Layer("badge", [disc((0, 0), BADGE_R + g)] + holed(mark((0, 0.3), 1.1, MARK_W(m))))]
        T = 2.6 + 1.2 * g
        return [Layer("ring", [disc((0, 0), 11.6 + T / 2), disc((0, 0), 11.6 - T / 2, hole=True)]),
                Layer("mark", mark((0, 0.3), 0.88, 3.0 + 1.2 * g))]
    return build


BADGE_R = 12.6
# 没有圆底的状态图形按这个倍数放大：同一行字里，系统的同类符号都比圆标宽、高出一截（气泡、星、闪电、光标 K，铃 BK，云最宽 CK，
# 照系统 bell、icloud 在同一字号下的实测宽高定）
K, BK, CK = 1.15, 1.3, 1.5


def sc(k, points): return [(x * k, y * k) for x, y in points]


def picked(m):
    """选上：反白符号，同系统 checkmark.circle.fill 的分层——勾在第一层，刻了勾槽的实心圆是第二层的底。
    调用方给两种颜色（勾色、底色）时按层上色；只给一种时单色，勾嵌在槽里。App 里不按层级渲染（`Icon` 的 `.filled`）。"""
    g, c = GROW[m], CARVE[m]
    w = MARK_W(m, 2.6)
    return [Layer("tick", mark_tick((0, 0.3), 1.1, w)),
            Layer("badge", [disc((0, 0), BADGE_R + g)] + holed(mark_tick((0, 0.3), 1.1, w + 2 * c)), "secondary", ground=True)]


def bubble_question(m):
    """等 Cue 回答：对话气泡（尾巴在左下）是一圈墨，问号自己一块嵌在里面——同未知的圆环，不急、不是要你管的，不用实心。"""
    g = GROW[m]
    T, top, bottom = 2.2 + 1.1 * g, -10.8, 5.8
    box, radii = [(-11, top), (11, top), (11, bottom), (-11, bottom)], [4.2] * 4
    outer = grown(sc(K, [(-11, top), (11, top), (11, bottom), (-0.8, bottom), (-6.4, 11.0), (-5.8, bottom), (-11, bottom)]), [4.2, 4.2, 4.2, 0.6, 0.6, 0.4, 4.2], g)
    return [Layer("bubble", [outer, rev(grown(sc(K, box), radii, g - T))]), Layer("mark", mark_question((0, K * (top + bottom) / 2 + 0.2), 0.58 * K, 3.2 + 1.0 * g))]


def ring_slash(m):
    """已结束：一圈圆环被一道斜杠劈断（环在斜杠两边各断开一条刻缝）。"""
    g, c = GROW[m], CARVE[m]
    T, r = 2.6 + 1.2 * g, 11.0
    w, bar_ = slash(m, r + T / 2)
    d = math.degrees(math.asin((w / 2 + c + T / 2) / r))
    return [Layer("ring", [bow((0, 0), r, 45 + d, 180 - 2 * d, T), bow((0, 0), r, 225 + d, 180 - 2 * d, T)]), Layer("slash", [bar_])]


BOLT = [(-1.4, -11.6), (6.6, -11.6), (2.0, -2.8), (7.8, -2.8), (-5.0, 11.8), (-1.4, 0.8), (-7.6, 0.8)]
BOLT_CUT = 4.2


def bolt_cut(m):
    """断了（做到一半停下）：一道闪电（上宽下尖的 Z 字折线，一块实心）在下半截的尾巴上被一道横缝截断，尖头断开。
    不压斜杠：杠与闪电交叉，小字号下读成 × 或星，闪电认不出；缝开在尾巴上（`BOLT_CUT` 格高处），上面整个 Z 字不动，12pt 也认得出。
    缝宽 `GAP` 加两侧刻缝，比一条刻缝宽，小字号下还看得见。"""
    g, c = GROW[m], CARVE[m]
    bolt = grown(sc(K, BOLT), [1.0, 1.0, 0, 0.9, 0.8, 0, 0.9], g)
    line = [mul((-16, BOLT_CUT), G), mul((16, BOLT_CUT), G)]
    off = (GAP / 2 + c) * G
    return [Layer("bolt", [clip(bolt, Along(line, off, 1)), clip(bolt, Along(line, -off, -1))])]


GAP = 1.0


def cursor(m):
    """该你了：一行字（一条圆角的块），后面跟着输入光标（工字：上下两道横、中间一竖）——轮到你接着打字。"""
    g, c = GROW[m], CARVE[m]
    x, hw, sw, top, cap = 5.4 * K, 4.0 * K, 1.5 + 0.6 * g, 10.8 * K + 0.5 * g, 2.7 + g
    pts = [(x - hw, -top), (x + hw, -top), (x + hw, -top + cap), (x + sw, -top + cap), (x + sw, top - cap), (x + hw, top - cap), (x + hw, top),
           (x - hw, top), (x - hw, top - cap), (x - sw, top - cap), (x - sw, -top + cap), (x - hw, -top + cap)]
    beam = rpoly(pts, [1.1, 1.1, 0.9, 0.8, 0.8, 0.9, 1.1, 1.1, 0.9, 0.8, 0.8, 0.9])
    right = x - hw - c - 2 * g
    block = grown([(-11.0 * K, -3.4 * K), (right, -3.4 * K), (right, 3.4 * K), (-11.0 * K, 3.4 * K)], [1.8] * 4, g)
    return [Layer("text", [block]), Layer("cursor", [beam])]


def star(c, R, q, g):
    """四角星（格）：四个尖是小圆角，尖与尖之间的腰是往里凹的弧。"""
    pts = []
    for k in range(4):
        a = math.radians(k * 90 - 90)
        pts.append((c[0] + R * math.cos(a), c[1] + R * math.sin(a)))
        b = a + math.pi / 4
        pts.append((c[0] + q * math.cos(b), c[1] + q * math.sin(b)))
    return rpoly(pts, [0.7 + 0.4 * g, R * 0.36] * 4)


def sparkle(m):
    """新会话：一颗四角星。"""
    g = GROW[m]
    return [Layer("star", [star((0, 0), 11.4 * K + g, 3.5 * K + g, g)])]


def sparkles(m):
    """Agent：一大一小两颗四角星，小的（右上）是点睛。"""
    g = GROW[m]
    return [Layer("star", [star((-2.4 * K, 2.4 * K), 9.2 * K + g, 2.8 * K + g, g)]),
            Layer("spark", [star((6.8 * K, -6.8 * K), 4.7 * K + 0.6 * g, 1.3 * K + 0.4 * g, g)], "secondary")]


def circle_arrow(m, count=1):
    """重来：绕圈的粗箭头。一支（要重新载入，绕 290°）或两支首尾相追（立即同步、换新上下文）。"""
    g = GROW[m]
    w, r = 3.2 + 1.3 * g, 9.4
    head = (3.6 * G, 4.2 * G + g * G)
    if count == 1:
        return [Layer("arrow", [arrow(arcs((0, 0.6), r, -40, 280), w * G, head)])]
    return [Layer(f"arrow{k}", [arrow(arcs((0, 0), r, 200 + 180 * k, 125), w * G, head)]) for k in range(2)]


def cloud_shape(g):
    """云：左小、中大、右中三个圆的上沿接起来，底边是平的。三段弧的段数写死，三个母版才能插值。"""
    L, T, R, bottom = ((-6.5 * CK, 3.2 * CK), 4.4 * CK + g), ((-0.7 * CK, -1.2 * CK), 6.4 * CK + g), ((5.3 * CK, 2.0 * CK), 5.6 * CK + g), 7.6 * CK + g
    def meet(a, b):
        (c1, r1), (c2, r2) = a, b
        d = dist(c1, c2); x = (d * d + r1 * r1 - r2 * r2) / (2 * d); y = math.sqrt(r1 * r1 - x * x)
        u = norm(sub(c2, c1))
        return min((add(add(c1, mul(u, x)), mul(left(u), s * y)) for s in (1, -1)), key=lambda p: p[1])
    def arc(circle, p, q, pieces):
        c, r = circle
        a0, a1 = ang(sub(p, c)), ang(sub(q, c))
        sw = (a1 - a0) % (2 * math.pi)
        assert sw / pieces < math.radians(100), "云的一段弧太长"
        return Arc(mul(c, G), r * G, a0, sw, pieces)
    lt, tr = meet(L, T), meet(T, R)
    lb, rb = (L[0][0], bottom), (R[0][0], bottom)
    return [arc(L, lb, lt, 2), arc(T, lt, tr, 2), arc(R, tr, rb, 3), Line(mul(rb, G), mul(lb, G))]


CLOUD_MARK = (0.2 * CK, 2.2 * CK)


def cloud(mark=None, scale=0.5):
    """同步一族：同一朵云，刻进去的记号说同步的状态——空（正在连接）、勾（已同步）、转圈（同步中）、叹号（出了问题）、暂停、上箭头（上传本机）、下箭头（用云端替换）。"""
    def build(m):
        body = cloud_shape(GROW[m])
        return [Layer("cloud", [body] + (holed(mark(CLOUD_MARK, scale * CK, MARK_W(m))) if mark else []))]
    return build


def cloud_slash(m):
    """没有在同步：云被斜杠劈开。"""
    w, bar_ = slash(m, 11.0 * CK, -0.8)
    return [Layer("cloud", slash_cut(cloud_shape(GROW[m]), m, w, -0.8)), Layer("slash", [bar_])]


LOCK = (7.4, 3.4)  # 锁体左上角的位置（乘 CK 之前的格）


def cloud_lock(m):
    """账号受限：云的右下角让出一个圆位（锁的外接圆再加一条刻缝），嵌一把锁（点睛）。锁体是一整块方墨、锁梁粗，12pt 下还是锁的样子。"""
    g, c = GROW[m], CARVE[m]
    x, top = LOCK[0] * CK, LOCK[1] * CK
    bw, bottom, r, t = 4.8 + 0.4 * g, top + 6.2 + 0.3 * g, 3.0, 2.3 + 0.5 * g
    lock = rpoly([(x - bw, top), (x + bw, top), (x + bw, bottom), (x - bw, bottom)], [1.0] * 4)
    shackle = bow((x, top), r, 180, 180, t)
    o = (x, (top - r - t / 2 + bottom) / 2)
    R = max(dist(sample(sg, k / 16), mul(o, G)) for ct in (lock, shackle) for sg in ct for k in range(17)) / G
    return [Layer("cloud", [clip(cloud_shape(g), Outside(o, R + c))]), Layer("lock", [lock, shackle], "secondary")]


def bell_shape(g):
    return grown(sc(BK, [(-6.6, -11.0), (6.6, -11.0), (6.6, 0.4), (9.8, 4.2), (9.8, 6.0), (-9.8, 6.0), (-9.8, 4.2), (-6.6, 0.4)]),
                 [6.5 * BK, 6.5 * BK, 3.0, 1.0, 0.8, 0.8, 1.0, 3.0], g)


def clapper(m):
    g, c = GROW[m], CARVE[m]
    r = 1.9 * BK + 0.5 * g
    return disc((0, 6.0 * BK + g + c + r), r)


def bell(m):
    """通知一族：铃身一块，铃舌（下面一颗）隔一条刻缝，是点睛——它回你了、开着通知。"""
    return [Layer("bell", [bell_shape(GROW[m])]), Layer("clapper", [clapper(m)], "secondary")]


def bell_on(m):
    """通知已开：铃的右上角让出一个圆位，嵌一颗角标（点睛）。"""
    g, c = GROW[m], CARVE[m]
    o, r = (8.0 * BK, -9.0 * BK), 2.8 * BK + 0.4 * g
    return [Layer("bell", [clip(bell_shape(g), Outside(o, r + c)), clapper(m)]), Layer("badge", [disc(o, r)], "secondary")]


def bell_off(m):
    """通知已关：铃被斜杠劈开。"""
    w, bar_ = slash(m, 11.0 * BK, -0.9)
    return [Layer("bell", slash_cut(bell_shape(GROW[m]), m, w, -0.9) + [clapper(m)]), Layer("slash", [bar_])]


# ---------- 动作与菜单（任务与卡片操作、导航入口）：一族一份几何 ----------

def turned(contours, deg):
    """整组轮廓（模板单位）绕原点转 deg 度：直线转端点，圆弧转圆心与起角，曲线转控制点。"""
    def t(p): return rot(p, deg)
    def seg(s):
        if isinstance(s, Line): return Line(t(s.a), t(s.b))
        if isinstance(s, Cubic): return Cubic(t(s.p0), t(s.p1), t(s.p2), t(s.p3))
        return Arc(t(s.c), s.r, s.a0 + math.radians(deg), s.sweep, s.pieces)
    return [[seg(s) for s in c] for c in contours]


def ring_mark(mark, scale=0.88):
    """圆环里嵌一个记号（同"未知"的圆标）：完成（勾）、重新打开（往回折的箭头）。"""
    def build(m):
        g = GROW[m]
        T = 2.6 + 1.2 * g
        return [Layer("ring", [disc((0, 0), 11.6 + T / 2), disc((0, 0), 11.6 - T / 2, hole=True)]),
                Layer("mark", mark((0, 0.3), scale, (3.0 + 1.2 * g) / scale * 0.88))]
    return build


def restore(m):
    """取回、恢复：一支往回折的粗箭头（同没能送达里刻的那支），不带圆。"""
    s = 1.75
    return [Layer("arrow", mark_uturn((0.4, 0.2), s, (2.9 + 1.2 * GROW[m]) / s))]


def play(m):
    """开始：一块圆角的实心三角，重心落在图形中心。"""
    g = GROW[m]
    return [Layer("play", [grown([(-6.0, -10.6), (10.8, 0), (-6.0, 10.6)], [2.4, 2.0, 2.4], g)])]


def indent(direction):
    """缩进 / 取消缩进：四行（上下两行满宽、中间两行让出左边），左边一个小三角指向右或左（点睛）。"""
    def build(m):
        g = GROW[m]
        w = 2.6 + 1.2 * g
        lines = [bar([(-10.0, y), (10.0, y)], w) for y in (-8.4, 8.4)] + [bar([(-0.4, y), (10.0, y)], w) for y in (-2.8, 2.8)]
        tri = [(-10.6, -3.6), (-4.4, 0), (-10.6, 3.6)] if direction > 0 else [(-4.4, -3.6), (-10.6, 0), (-4.4, 3.6)]
        return [Layer("lines", lines), Layer("arrow", [grown(tri if direction > 0 else tri[::-1], [0.8] * 3, g * 0.8)], "secondary")]
    return build


def chain(linked):
    """链接 / 解除链接：两只 U 形的环（开口相对）斜着摆，连上时中间一截短杠把它们串起来（点睛）；解开时两环拉开、没有杠。"""
    def build(m):
        g = GROW[m]
        w, h, end = 2.8 + 1.2 * g, 4.4 + 1.4 * g, 2.4 + 0.4 * g
        apart = 0 if linked else 1.6
        a = bar([(-end - apart, -h), (-6.4 - apart, -h), (-6.4 - apart - h, 0), (-6.4 - apart, h), (-end - apart, h)], w, [0, h * 0.98, h * 0.98, h * 0.98, 0])
        b = bar([(end + apart, -h), (6.4 + apart, -h), (6.4 + apart + h, 0), (6.4 + apart, h), (end + apart, h)], w, [0, h * 0.98, h * 0.98, h * 0.98, 0])
        layers = [Layer("a", turned([a], -45)), Layer("b", turned([b], -45))]
        if linked:
            layers.append(Layer("bar", turned([bar([(-3.4, 0), (3.4, 0)], w)], -45), "secondary"))
        return layers
    return build


FOLDER_SEAM = -3.4


def folder_shape(g, c):
    """文件夹：后片（带左上的页签）与前片之间一道平刀口。"""
    back = grown([(-11, -9.0), (-3.0, -9.0), (-1.0, -6.4), (11, -6.4), (11, FOLDER_SEAM - c - 2 * g), (-11, FOLDER_SEAM - c - 2 * g)],
                 [1.6, 0.6, 0.6, 1.6, 0, 0], g)
    front = grown([(-11, FOLDER_SEAM), (11, FOLDER_SEAM), (11, 9.0), (-11, 9.0)], [0, 0, 2.2, 2.2], g)
    return back, front


def mark_plus(c, s, w):
    return [cross_shape_at(c, 4.4 * s, w * s / 2)]


def cross_shape_at(c, L, hw):
    pts = [(-hw, -L), (hw, -L), (hw, -hw), (L, -hw), (L, hw), (hw, hw), (hw, L), (-hw, L), (-hw, hw), (-L, hw), (-L, -hw), (-hw, -hw)]
    return rpoly([(c[0] + x, c[1] + y) for x, y in pts], [hw * 0.9, hw * 0.9, 0] * 4)


def mark_minus(c, s, w):
    return [bar([(c[0] - 4.0 * s, c[1]), (c[0] + 4.0 * s, c[1])], w * s)]


FOLDER_BADGE = (7.6, 6.0)


def folder(mark=None):
    """文件夹一族：文件夹（项目绑的目录）；右下让出一个圆位嵌一颗角标（点睛），角标里刻 +（新建项目）、−（解除绑定）、?（文件夹找不到了）。"""
    def build(m):
        g, c = GROW[m], CARVE[m]
        back, front = folder_shape(g, c)
        if not mark:
            return [Layer("folder", [back, front])]
        r = 4.9 + 0.4 * g
        front = clip(front, Outside(FOLDER_BADGE, r + c))
        badge = [disc(FOLDER_BADGE, r)] + holed(mark(FOLDER_BADGE, 0.62, MARK_W(m, 3.2)))
        return [Layer("folder", [back, front]), Layer("badge", badge, "secondary")]
    return build


def books(m):
    """资料：书架上三本书，前两本立着（一高一矮）、第三本斜靠，书与书之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    out = [grown([(x0, top), (x1, top), (x1, 10.4), (x0, 10.4)], [1.0] * 4, g)
           for x0, x1, top in ((-11.0, -5.6, -10.4), (-5.6 + c + 2 * g, -0.6, -7.6))]
    lean = [(x + 2.6, y + 0.6) for x, y in (rot(p, 16) for p in [(0, -10.6), (5.0, -10.6), (5.0, 9.6), (0, 9.6)])]
    out.append(grown(lean, [1.0] * 4, g))
    return [Layer("books", out)]


def pin_parts(g, c):
    """竖着的图钉：钉帽、钉身、钉尖三块，之间各一条横的刻缝。不斜放：斜放时刻缝正好与取消置顶的斜杠平行，斜杠读成又一道缝。"""
    k = 1.2
    head = grown(sc(k, [(-4.6, -11.0), (4.6, -11.0), (4.6, -8.2), (-4.6, -8.2)]), [1.4, 1.4, 0.6, 0.6], g)
    top = -8.2 * k + g + c + g
    body = grown([(-2.8 * k, top), (2.8 * k, top)] + sc(k, [(2.8, -2.2), (5.8, 1.2), (5.8, 3.0), (-5.8, 3.0), (-5.8, 1.2), (-2.8, -2.2)]),
                 [0, 0, 1.6, 0.8, 0.6, 0.6, 0.8, 1.6], g)
    nw = 1.6 + 0.6 * g
    needle = bar([(0, 3.0 * k + g + c + nw / 2), (0, 10.8 * k)], nw)
    return head, body, needle


def pin(m):
    """置顶：一枚图钉，钉尖是点睛。"""
    head, body, needle = pin_parts(GROW[m], CARVE[m])
    return [Layer("pin", [head, body]), Layer("needle", [needle], "secondary")]


UNPIN_K = -1.0  # 斜杠往右上平移多少格（切口避开三个母版结构不一的位置）


def unpin(m):
    """取消置顶：同"没有在同步""通知已关"，一道斜杠斜着贯穿图钉，钉身被劈开、切口一条刻缝；斜杠与横的刻缝成 45°，12pt 也看得出被划掉。"""
    head, body, needle = pin_parts(GROW[m], CARVE[m])
    w, bar_ = slash(m, 13.0, UNPIN_K)
    return [Layer("pin", [p for part in (head, body, needle) for p in slash_cut(part, m, w, UNPIN_K)]), Layer("slash", [bar_])]


def sheets(fold):
    """两张叠着的纸：前一张整张，后一张只露出左上的 L 形（被前一张挡住的地方让出一条刻缝）。
    fold：前一张右上折角（拷贝，纸的折角是点睛）；不折是两个版本（冲突）。"""
    def build(m):
        g, c = GROW[m], CARVE[m]
        bx0, by0, fx0, fy0, x1, y1 = -11.0, -11.0, -5.4, -5.4, 11.0, 11.0
        bx1, by1 = x1 - 5.6, y1 - 5.6
        back = grown([(bx0, by0), (bx1, by0), (bx1, fy0 - c - 2 * g), (fx0 - c - 2 * g, fy0 - c - 2 * g), (fx0 - c - 2 * g, by1), (bx0, by1)],
                     [2.4, 2.4, 0, 0, 0.8, 2.4], g)
        if not fold:
            return [Layer("sheets", [back, grown([(fx0, fy0), (x1, fy0), (x1, y1), (fx0, y1)], [2.4] * 4, g)])]
        e = 5.0 + g * 0.5
        front = grown([(fx0, fy0), (x1 - e - c, fy0), (x1 - e - c, fy0 + e + c), (x1, fy0 + e + c), (x1, y1), (fx0, y1)], [2.4, 0.4, 0, 0.4, 2.4, 2.4], g)
        ear = rpoly([(x1 - e + g, fy0 - g), (x1 + g, fy0 + e - g), (x1 - e + g, fy0 + e - g)], [0.6, 0.6, 0])
        return [Layer("sheets", [back, front]), Layer("ear", [ear], "secondary")]
    return build


def deck(m):
    """全部：错开的一叠卡片，前一张完整，后两张同样大、依次往右上错开，只露出上边与右边的 L 形，各隔一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    d, size = 3.6, 14.8
    out = []
    for k in range(3):
        x0, y1 = -11.0 + k * d, 11.0 - k * d
        x1, y0 = x0 + size, y1 - size
        if k == 0:
            out.append(grown([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], [2.4] * 4, g))
            continue
        ix, iy = x1 - d + c + 2 * g, y0 + d - c - 2 * g
        out.append(grown([(x0, y0), (x1, y0), (x1, y1), (ix, y1), (ix, iy), (x0, iy)], [1.4, 2.4, 1.4, 0.4, 0, 0.4], g))
    return [Layer("deck", out)]


def stack(m):
    """全部会话：前面一张横长的圆角块，后面两条越来越窄的边露在上面，各隔一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    hw, top, bottom = 11.0, -3.0, 9.0
    out = [grown([(-hw, top), (hw, top), (hw, bottom), (-hw, bottom)], [2.4] * 4, g)]
    y = top - c - 2 * g
    for inset in (1.8, 3.6):
        h = 2.4 + 0.5 * g
        out.append(grown([(-hw + inset, y - h), (hw - inset, y - h), (hw - inset, y), (-hw + inset, y)], [1.2, 1.2, 0, 0], g * 0.5))
        y -= h + c + g
    return [Layer("stack", out)]


def grid(m):
    """全部项目：田字四块圆角方，块间一道宽于刻缝的缝。"""
    g = GROW[m]
    a, gap = 10.6, 1.4
    out = []
    for x0, y0 in ((-a, -a), (gap, -a), (-a, gap), (gap, gap)):
        out.append(grown([(x0, y0), (x0 + a - gap, y0), (x0 + a - gap, y0 + a - gap), (x0, y0 + a - gap)], [2.4] * 4, g))
    return [Layer("grid", out)]


def tray_arrow(up):
    """分享（箭头从托盘里往上出去）/ 存成灵感（箭头往下落进托盘）：一只 U 形托盘，上沿两臂之间留口，箭头穿过口子，各隔一条刻缝。"""
    def build(m):
        g = GROW[m]
        w = 2.8 + 1.2 * g
        tray = bar([(-5.0, -2.4), (-9.6, -2.4), (-9.6, 10.0), (9.6, 10.0), (9.6, -2.4), (5.0, -2.4)], w, [0, 2.6, 2.6, 2.6, 2.6, 0])
        head = (4.0 * G, 4.6 * G + g * G)
        if up:
            a = arrow([Line(mul((0, 3.6), G), mul((0, -7.0), G))], w * G, head)
        else:
            a = arrow([Line(mul((0, -12.0), G), mul((0, 0.4), G))], w * G, head)
        return [Layer("tray", [tray]), Layer("arrow", [a])]
    return build


def pencil_parts(a, b, w, c):
    """一支铅笔（模板单位以外都按格）：a 是笔尖，b 是笔尾；笔尖一小块三角（点睛）、笔杆一块，之间一条刻缝。"""
    d = norm(sub(b, a)); n = left(d)
    tip_len = w * 1.25
    base = add(a, mul(d, tip_len))
    tip = rpoly([a, add(base, mul(n, w / 2)), sub(base, mul(n, w / 2))], [0.5, 0, 0])
    s = add(base, mul(d, c))
    body = rpoly([add(s, mul(n, w / 2)), add(b, mul(n, w / 2)), sub(b, mul(n, w / 2)), sub(s, mul(n, w / 2))], [0, 1.2, 1.2, 0])
    return tip, body


def pencil(m):
    """重命名、改文件：一支斜放的铅笔，笔尖朝左下，笔尖是点睛。"""
    g, c = GROW[m], CARVE[m]
    tip, body = pencil_parts((-9.6, 9.6), (9.2, -9.2), 5.0 + 1.2 * g, c)
    return [Layer("pencil", [body]), Layer("tip", [tip], "secondary")]


def write(m):
    """写：一张纸（圆角方框，右上让出一个口）上斜放一支铅笔，笔尖落在纸里，笔尖是点睛。"""
    g, c = GROW[m], CARVE[m]
    w = 2.6 + 1.2 * g
    box = bar([(-1.0, -9.6), (-9.6, -9.6), (-9.6, 9.6), (9.6, 9.6), (9.6, 1.0)], w, [0, 2.8, 2.8, 2.8, 0])
    tip, body = pencil_parts((-3.0, 3.0), (11.4, -11.4), 4.4 + 1.1 * g, c)
    return [Layer("paper", [box, body]), Layer("tip", [tip], "secondary")]


def choose(m):
    """挑选（下拉）：上下两块实心 V（同箭头的块），一朝上一朝下。"""
    g = GROW[m] * 0.8
    half, drop, t, dy = 5.6, 4.4, 2.8, 5.2
    top = -(drop + t) / 2
    up = [(0, top), (half, top + drop), (half, top + drop + t), (0, top + t), (-half, top + drop + t), (-half, top + drop)]
    radii = [0.6, 0.5, 0.5, 0, 0.5, 0.5]
    # 朝下的那块是朝上的上下翻过来：翻转后走向成了逆时针，点序倒过来
    down = [(x, -y + dy) for x, y in up][::-1]
    return [Layer("up", [grown([(x, y - dy) for x, y in up], radii, g)]), Layer("down", [grown(down, radii[::-1], g)])]


def filter_lines(m):
    """筛选：三道居中的横条，一道比一道短。"""
    g = GROW[m]
    w = 2.8 + 1.2 * g
    return [Layer("lines", [bar([(-h, y), (h, y)], w) for h, y in ((10.0, -7.0), (6.4, 0), (2.8, 7.0))])]


def puzzle(m):
    """扩展：一块拼图——方块的上边与右边各凸出一个圆头。"""
    g = GROW[m]
    body = grown([(-9.6, -6.4), (6.4, -6.4), (6.4, 9.6), (-9.6, 9.6)], [2.0] * 4, g)
    return [Layer("piece", [body, disc((-1.6, -8.4), 3.4 + g), disc((8.4, 1.6), 3.4 + g)])]


# ---------- 输入、发送与会话：纸飞机、箭头、圆环记号、气泡、窗口、相片、角色几族 ----------

PLANE = sc(K, [(11.0, -10.4), (-11.0, -0.6), (-2.6, 2.8), (0.6, 11.0)])  # 机头、左翼尖、折痕底、下翼尖（格）；三角的墨比方块少，同气泡一样放大 K


def plane(m):
    """交给（转交给 Cue、会话里转给别人的那一步）：一架纸飞机，机头朝右上；一道折痕从机头斜下来，把机身切成上翼与下翼两块。"""
    g, c = GROW[m] * 0.6, CARVE[m]
    nose, wing, fold, tail = PLANE
    k = c + 2 * g  # 两翼各外扩 g 之后正好一条刻缝
    n = left(norm(sub(fold, nose)))
    n = n if (tail[0] - nose[0]) * n[0] + (tail[1] - nose[1]) * n[1] > 0 else mul(n, -1)
    a, b = add(nose, mul(n, k)), add(fold, mul(n, k))
    upper = grown([fold, wing, nose], [0.9, 1.0, 0.9], g)
    lower = grown([tail, meet(a, b, fold, tail), meet(a, b, nose, tail)], [1.0, 0.9, 0.9], g)
    return [Layer("upper", [upper]), Layer("lower", [lower])]


def meet(p1, p2, q1, q2):
    """两条直线（各过两点）的交点。"""
    d1, d2 = sub(p2, p1), sub(q2, q1)
    t = cross(sub(q1, p1), d2) / cross(d1, d2)
    return add(p1, mul(d1, t))


def plane_done(m):
    """已送达：纸飞机（同交给），右下的空角里嵌一个小勾（点睛），离飞机一条刻缝。"""
    g = GROW[m]
    tick = bar([(7.0, 9.6), (9.2, 11.8), (13.6, 7.2)], 2.4 + 1.0 * g)
    return plane(m) + [Layer("tick", [tick], "secondary")]


def seg_scaled(s, k, d):
    """一段轮廓（模板单位）以原点缩放 k 再平移 d。"""
    def t(p): return add(mul(p, k), d)
    if isinstance(s, Line): return Line(t(s.a), t(s.b))
    if isinstance(s, Cubic): return Cubic(t(s.p0), t(s.p1), t(s.p2), t(s.p3))
    return Arc(t(s.c), s.r * k, s.a0, s.sweep, s.pieces)


def tick(m):
    """保存、选中：做完里那一笔粗勾（圆头、直刀口的体块），不带 C 环，放大一点、挪到中心。"""
    k = 1.25
    cx, cy = 3.3, -3.2  # 勾的外接框中心
    return [Layer("tick", [bar([((x - cx) * k, (y - cy) * k) for x, y in DONE_TICK], (3.3 + 1.0 * GROW[m]) * k)])]


def dart(deg, s=1.0, at=(0.0, 0.0)):
    """发送那一支箭（`send_parts`）转 deg 度（0 朝上、90 朝右）、缩放 s、挪到 at（格）：箭头一族的同一份几何。"""
    def build(g, c):
        return [[seg_scaled(sg, 1.0, mul(at, G)) for sg in ct] for ct in turned(list(send_parts(g, c, s)), deg)]
    return build


def arrow_down(m):
    """回到最新：发送那一支箭朝下。"""
    shaft, head = dart(180)(GROW[m], CARVE[m])
    return [Layer("shaft", [shaft]), Layer("head", [head])]


def compact(m):
    """压缩上下文：两支发送的箭（缩小）从左上、右下往中间收，箭尖之间隔一道缝。"""
    g, c = GROW[m], CARVE[m]
    s, tip = 0.72, 1.0  # 箭尖离中心多少格（沿对角线的分量）
    d = tip + 12.0 * s * 0.7071
    return [Layer("a", dart(135, s, (-d, -d))(g, c)), Layer("b", dart(-45, s, (d, d))(g, c))]


def bolt(m):
    """插话：一道闪电（同"断了"的那道，不截断）。"""
    return [Layer("bolt", [grown(sc(K, BOLT), [1.0, 1.0, 0, 0.9, 0.8, 0, 0.9], GROW[m])])]


def mark_square(c, s, w):
    h = 4.4 * s
    return [rpoly([(c[0] - h, c[1] - h), (c[0] + h, c[1] - h), (c[0] + h, c[1] + h), (c[0] - h, c[1] + h)], [1.2 * s] * 4)]


def mark_play(c, s, w):
    return [rpoly([at(c, s, p) for p in ((-3.4, -5.6), (5.8, 0), (-3.4, 5.6))], [1.2 * s, 1.0 * s, 1.2 * s])]


def mark_hands(c, s, w):
    return [bar([at(c, s, (0, -6.0)), at(c, s, (0, 0)), at(c, s, (4.4, 2.8))], w * s)]


def bubble_outline(g, T):
    """对话气泡（尾巴在左下）的一圈墨（同等 Cue 回答），返回轮廓与气泡里的中心。"""
    top, bottom = -10.8, 5.8
    box, radii = [(-11, top), (11, top), (11, bottom), (-11, bottom)], [4.2] * 4
    outer = grown(sc(K, [(-11, top), (11, top), (11, bottom), (-0.8, bottom), (-6.4, 11.0), (-5.8, bottom), (-11, bottom)]), [4.2, 4.2, 4.2, 0.6, 0.6, 0.4, 4.2], g)
    return [outer, rev(grown(sc(K, box), radii, g - T))], (0, K * (top + bottom) / 2)


def bubble(kind):
    """说了一句（气泡里两行字）/ 在想（气泡里三个点）：气泡是一圈墨，里面的记号自己一块。"""
    def build(m):
        g = GROW[m]
        ring, (cx, cy) = bubble_outline(g, 2.2 + 1.1 * g)
        w = 2.4 + 0.9 * g
        if kind == "text":
            mark = [bar([(cx - 6.4, cy - 2.6), (cx + 6.4, cy - 2.6)], w), bar([(cx - 6.4, cy + 2.6), (cx + 2.0, cy + 2.6)], w)]
        else:
            mark = [disc((cx + dx, cy + 0.2), 1.6 + 0.5 * g) for dx in (-5.2, 0, 5.2)]
        return [Layer("bubble", ring), Layer("mark", mark)]
    return build


def mac(m):
    """Mac：一块屏（圆角实心）下面一只 T 形的座，屏与座之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    screen = grown([(-11.0, -10.0), (11.0, -10.0), (11.0, 4.4), (-11.0, 4.4)], [2.4] * 4, g)
    top = 4.4 + c + 2 * g
    stand = grown([(-2.6, top), (2.6, top), (3.0, 8.0), (6.8, 8.0), (6.8, 10.4), (-6.8, 10.4), (-6.8, 8.0), (-3.0, 8.0)],
                  [0, 0, 0.6, 1.0, 1.0, 1.0, 1.0, 0.6], g)
    return [Layer("screen", [screen]), Layer("stand", [stand])]


def window(m):
    """终端窗口：一扇窗——上面一条标题栏，左端刻出三颗小圆（红绿灯），与窗身之间一道比刻缝宽的横缝，12pt 也分得开。"""
    g, c = GROW[m], CARVE[m]
    y0, split, y1 = -10.0, -4.0, 10.0
    gap = c + GAP  # 两块各外扩 g 之后还剩这么宽
    bar_ = grown([(-11.0, y0), (11.0, y0), (11.0, split), (-11.0, split)], [2.6, 2.6, 0.4, 0.4], g)
    lights = [disc((x, (y0 + split) / 2), 1.3 - 0.25 * g, hole=True) for x in (-7.4, -3.6, 0.2)]
    body = grown([(-11.0, split + gap + 2 * g), (11.0, split + gap + 2 * g), (11.0, y1), (-11.0, y1)], [0.4, 0.4, 2.6, 2.6], g)
    return [Layer("window", [body]), Layer("title", [bar_] + lights)]


def terminal(m):
    """终端、命令：一块圆角实心的屏，刻出提示符 > 与一道下划线。"""
    g = GROW[m]
    w = MARK_W(m, 3.0)
    screen = grown([(-11.0, -9.6), (11.0, -9.6), (11.0, 9.6), (-11.0, 9.6)], [2.8] * 4, g)
    prompt = bar([(-6.4, -4.2), (-2.0, 0), (-6.4, 4.2)], w)
    line = bar([(0.8, 4.4), (6.6, 4.4)], w)
    return [Layer("screen", [screen] + holed([prompt, line]))]


def paper(mark=None):
    """文档一族：一张纸，右上折角（点睛，同拷贝），刻在纸上的记号换意思——三行字（读文件、文稿），什么都不刻（认不出类型的文件）。"""
    def build(m):
        g, c = GROW[m], CARVE[m]
        x0, y0, x1, y1 = -8.6, -11.0, 8.6, 11.0
        e = 5.6 + g * 0.5
        page = grown([(x0, y0), (x1 - e - c, y0), (x1 - e - c, y0 + e + c), (x1, y0 + e + c), (x1, y1), (x0, y1)], [2.2, 0.4, 0, 0.4, 2.2, 2.2], g)
        ear = rpoly([(x1 - e + g, y0 - g), (x1 + g, y0 + e - g), (x1 - e + g, y0 + e - g)], [0.6, 0.6, 0])
        return [Layer("page", [page] + holed(mark(MARK_W(m, 2.4)) if mark else [])), Layer("ear", [ear], "secondary")]
    return build


def paper_lines(w):
    return [bar([(-4.4, y), (4.4, y)], w) for y in (0.6, 5.2)] + [bar([(-4.4, -4.0), (-1.0, -4.0)], w)]


def wrench(m):
    """工具：一把扳手，斜着放，钳口朝右上张开；钳口与把手之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    o, r, T = (4.0, -4.0), 4.6, 3.4 + 1.3 * g
    jaw = bow(o, r, 10, 250, T)
    hw = 4.0 + 1.4 * g
    d = (r + T / 2 + c + hw / 2) * 0.7071
    handle = bar([(o[0] - d, o[1] + d), (-9.2, 9.2)], hw)
    return [Layer("wrench", [jaw, handle])]


def branch(m):
    """分出去（子代理）：主干一竖；从主干中段斜出一枝往右上，枝在主干边上被一道竖的刀口切开；枝头一颗点（点睛）。"""
    g, c = GROW[m], CARVE[m]
    w = 3.0 + 1.2 * g
    x = -5.4
    trunk = bar([(x, 10.8), (x, -10.8)], w)
    a, b = (x, 5.0), (4.4, -4.8)
    arm = clip(bar([a, b], w), Along([mul((x, 16), G), mul((x, -16), G)], -(w / 2 + c) * G, -1))
    r = 2.6 + 0.5 * g
    u = norm(sub(b, a))
    knot = disc(add(b, mul(u, w / 2 + c + r)), r)
    return [Layer("branch", [trunk, arm]), Layer("knot", [knot], "secondary")]


def dot(m):
    """标为未读：一颗实心圆点。"""
    return [Layer("dot", [disc((0, 0), 6.6 + GROW[m])])]


def flame(m):
    """FireCode：一簇火苗（主焰尖偏右，左边再窜起一小舌），里面挖出一颗小火苗的槽，嵌着内焰（点睛）。"""
    g, c = GROW[m], CARVE[m]
    outer = [(1.4, -12.2), (5.2, -6.8), (8.8, -1.8), (9.4, 3.6), (6.6, 8.8), (0, 11.2), (-6.6, 8.8), (-9.4, 3.6), (-8.8, -1.6), (-6.8, -6.8), (-4.0, -3.4), (-1.8, -7.8)]
    core = [(0.4, -2.0), (2.4, 1.6), (3.1, 4.6), (2.0, 7.0), (0, 7.7), (-2.0, 7.0), (-3.1, 4.6), (-2.2, 2.0)]
    def curve(pts, d): return [seg_scaled(sg, G, (0, 0)) for sg in catmull(spread(pts, d), closed=True)]
    return [Layer("flame", [curve(outer, g), rev(curve(core, 0.42 * g + c * 1.5))]), Layer("core", [curve(core, 0.42 * g)], "secondary")]


def spread(pts, d):
    """闭合折线（顺时针）的每个点沿外法线推出 d 格：平滑曲线的近似等距。"""
    n, out = len(pts), []
    for i in range(n):
        t = norm(sub(pts[(i + 1) % n], pts[i - 1]))
        out.append(add(pts[i], mul(left(t), d)))
    return out


def hand(m):
    """拒绝：举起的手——掌一块，四指一根根竖着、各隔一条刻缝，拇指斜在左边。"""
    g, c = GROW[m], CARVE[m]
    palm = grown([(-7.6, 0.4), (7.6, 0.4), (7.6, 6.0), (4.0, 11.2), (-4.0, 11.2), (-7.6, 6.0)], [0.6, 0.6, 3.4, 2.4, 2.4, 3.4], g)
    fw = 2.6 + 0.5 * g
    top = 0.4 - g - c - fw / 2
    fingers = [bar([(x, top), (x, y)], fw) for x, y in ((-5.85, -6.6), (-1.95, -10.0), (1.95, -10.6), (5.85, -8.4))]
    thumb = bar([(-7.6 - g - c - fw / 2, 6.2), (-11.2, 1.4)], fw)
    return [Layer("hand", [palm] + fingers + [thumb])]


def camera(m):
    """拍照：机身一块，顶上一块小机顶隔一条刻缝；机身挖一圈镜头槽，嵌着镜头（点睛）。"""
    g, c = GROW[m], CARVE[m]
    body = grown([(-11.0, -5.0), (11.0, -5.0), (11.0, 9.4), (-11.0, 9.4)], [2.6] * 4, g)
    hump = grown([(-5.2, -9.4), (5.2, -9.4), (6.8, -5.0 - c - 2 * g), (-6.8, -5.0 - c - 2 * g)], [1.2, 1.2, 0, 0], g)
    o, r = (0, 2.4), 3.0 + 0.6 * g
    slot = disc(o, r + c + 1.4, hole=True)
    return [Layer("camera", [body, slot, hump]), Layer("lens", [disc(o, r)], "secondary")]


def photo_parts(x0, y0, x1, y1, g, c, T):
    """相片：一圈相框（圆角）里一座山（两个峰，一块实心），右上一颗太阳（点睛）。"""
    frame = [grown([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], [2.6] * 4, g),
             rev(grown([(x0 + T, y0 + T), (x1 - T, y0 + T), (x1 - T, y1 - T), (x0 + T, y1 - T)], [1.0] * 4, -g))]
    ix0, iy1, ix1 = x0 + T + g + c, y1 - T - g - c, x1 - T - g - c
    w, h = ix1 - ix0, iy1 - (y0 + T + g + c)
    peaks = [(ix0, iy1), (ix0, iy1 - h * 0.3), (ix0 + w * 0.32, iy1 - h * 0.72), (ix0 + w * 0.56, iy1 - h * 0.36), (ix0 + w * 0.68, iy1 - h * 0.46), (ix1, iy1 - h * 0.12), (ix1, iy1)]
    mountain = rpoly(peaks, [0.4, 0.4, 0.9, 0.5, 0.8, 0.4, 0.4])
    r = w * 0.1
    sun = disc((ix1 - r - 1.8, y0 + T + g + c + r + 1.4), r + 0.3 * g)
    return frame, mountain, sun


def photo(m):
    """图片：一张相片。"""
    g, c = GROW[m], CARVE[m]
    frame, mountain, sun = photo_parts(-11.0, -9.0, 11.0, 9.0, g, c, 2.4)
    return [Layer("photo", frame + [mountain]), Layer("sun", [sun], "secondary")]


def photos(m):
    """相册：一张相片往左下让，后面一张往右上错开，只露出上边与右边的 L 形（同全部的错开一叠）。"""
    g, c = GROW[m], CARVE[m]
    d = 3.6
    x0, y0, x1, y1 = -11.0, -9.0 + d, 11.0 - d, 11.0
    frame, mountain, sun = photo_parts(x0, y0, x1, y1, g, c, 2.2)
    bx0, by0, bx1, by1 = x0 + d, y0 - d, x1 + d, y1 - d
    ix, iy = bx1 - d + c + 2 * g, by0 + d - c - 2 * g
    back = grown([(bx0, by0), (bx1, by0), (bx1, by1), (ix, by1), (ix, iy), (bx0, iy)], [1.4, 2.4, 1.4, 0.4, 0, 0.4], g)
    return [Layer("photo", frame + [mountain, back]), Layer("sun", [sun], "secondary")]


def keyboard_down(m):
    """收起键盘：一块键盘（刻出两排键与空格）下面一个朝下的 V（点睛），隔一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    board = grown([(-11.0, -10.4), (11.0, -10.4), (11.0, 3.4), (-11.0, 3.4)], [2.4] * 4, g)
    k = 1.25 - 0.2 * g
    keys = [disc((x, y), k) for y in (-6.8, -3.0) for x in (-6.6, -2.2, 2.2, 6.6)]
    space = bar([(-4.4, 0.6), (4.4, 0.6)], 2 * k)
    v = bar([(-4.6, 7.2), (0, 10.6), (4.6, 7.2)], 2.6 + 1.0 * g)
    return [Layer("board", [board] + holed(keys + [space])), Layer("hide", [v], "secondary")]


def braces(m):
    """变量取值：一对花括号。"""
    g = GROW[m]
    w = 2.6 + 1.2 * g
    left_ = [(-2.4, -10.8), (-6.0, -10.8), (-6.0, -3.0), (-9.8, 0), (-6.0, 3.0), (-6.0, 10.8), (-2.4, 10.8)]
    radii = [0, 2.6, 2.2, 2.2, 2.2, 2.6, 0]
    return [Layer("braces", [bar(left_, w, radii), bar([(-x, y) for x, y in left_], w, radii)])]


def select_text(m):
    """选择文本：一截选中的字（实心块），两头各立一根选择柄，柄头一颗圆点（一个在上、一个在下），柄与块之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    w = 2.2 + 0.9 * g
    hx = 9.4
    block = grown([(-hx + w / 2 + c + g, -4.0), (hx - w / 2 - c - g, -4.0), (hx - w / 2 - c - g, 4.0), (-hx + w / 2 + c + g, 4.0)], [1.0] * 4, g)
    r = 2.4 + 0.5 * g
    left_ = [bar([(-hx, -5.4), (-hx, 6.8)], w), disc((-hx, -6.4 - r * 0.6), r)]
    right_ = [bar([(hx, -6.8), (hx, 5.4)], w), disc((hx, 6.4 + r * 0.6), r)]
    return [Layer("text", [block]), Layer("handles", left_ + right_)]


def hammer(m):
    """工程师：一把锤子斜着放（锤头在右上），锤头一块、锤柄一根，之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    # 斜放后外接框会缩到七成，竖着画时比别的图形长一截
    head = grown([(-8.6, -14.2), (5.0, -14.2), (9.8, -11.8), (9.8, -10.0), (5.0, -7.8), (-8.6, -7.8)], [1.4, 0.4, 1.0, 1.0, 0.4, 1.4], g)
    w = 3.6 + 1.4 * g
    handle = bar([(-1.0, -7.8 + g + c + w / 2), (-1.0, 14.6)], w)
    return [Layer("hammer", turned([head, handle], 45))]


def layers3(m):
    """批量工：三层叠起来的板——上面一块完整的菱形，下面两条同斜率的 V 形板边，各隔一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    hw, drop, t = 11.0, 6.0, 2.8
    cut = (c + 2 * g) / math.cos(math.atan(drop / hw))
    top = -10.4
    out = [grown([(0, top), (hw, top + drop), (0, top + 2 * drop), (-hw, top + drop)], [1.2, 1.0, 1.2, 1.0], g)]
    y = top + drop + cut
    for _ in range(2):
        out.append(grown([(-hw, y), (0, y + drop), (hw, y), (hw, y + t), (0, y + drop + t), (-hw, y + t)], [0.8, 0, 0.8, 0.8, 1.0, 0.8], g))
        y += t + cut
    return [Layer("layers", out)]


def brush(m):
    """设计师：一支画笔斜着放（笔头朝左下），笔杆、笔箍、笔头三块，各隔一条刻缝。笔头占了三成墨，不当点睛。"""
    g, c = GROW[m], CARVE[m]
    w = 3.4 + 1.3 * g
    handle = bar([(0, -14.6), (0, -4.2)], w)
    f0 = -4.2 + w / 2 + c
    ferrule = grown([(-3.2, f0 + g), (3.2, f0 + g), (3.2, 1.0), (-3.2, 1.0)], [0.4, 0.4, 0, 0], g)
    b0 = 1.0 + g + c + g
    tip = grown([(-3.2, b0), (3.2, b0), (2.8, 6.8), (0, 14.6), (-2.8, 6.8)], [0.4, 0.4, 2.8, 0.9, 2.8], g)
    return [Layer("brush", turned([handle, ferrule], 45)), Layer("tip", turned([tip], 45))]


def eye(m):
    """哨兵：一只盯着的眼——杏仁形的一块，挖一圈虹膜的槽，嵌着瞳孔（点睛）。"""
    g, c = GROW[m], CARVE[m]
    hw, rise = 11.6, 7.6
    r = (hw * hw + rise * rise) / (2 * rise)  # 上下两段弧过眼角与眼睑最高点
    a = math.degrees(math.acos((r - rise) / (r + g)))  # 外扩后两段弧仍在眼角（y=0）相接
    almond = [*arcs((0, r - rise), r + g, -90 - a, 2 * a), *arcs((0, -(r - rise)), r + g, 90 - a, 2 * a)]
    o, p = (0, 0), 2.6 + 0.5 * g
    return [Layer("eye", [almond, disc(o, p + c + 1.6, hole=True)]), Layer("pupil", [disc(o, p)], "secondary")]


def person(m):
    """子代理：一个人——圆头，下面是圆肩的半身，之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    o, r = (0, -5.4), 5.0
    head = disc(o, r + g)
    top = o[1] + r + g + c + g
    body = grown([(-10.0, 11.0), (-10.0, top + 5.6), (-5.0, top), (5.0, top), (10.0, top + 5.6), (10.0, 11.0)], [1.4, 4.6, 3.0, 3.0, 4.6, 1.4], g)
    return [Layer("person", [head, body])]


# ---------- Cue 与设置、文件预览的类型 ----------

def badge_dart(deg):
    """实心圆里刻出发送钮那一支燕尾箭（同一份几何，缩小）：朝上是发送回答，朝下是自动检查更新。"""
    def build(m):
        g, c = GROW[m], CARVE[m]
        return [Layer("badge", [disc((0, 0), BADGE_R + g)] + holed(dart(deg, 0.62, (0, 0.6 if deg == 0 else -0.6))(0.0, c)))]
    return build


def bookmark(m):
    """Cue 记得什么：一枚书签——上沿圆角的长条，下端剪出一个 V 口。"""
    g = GROW[m]
    return [Layer("bookmark", [grown([(-7.4, -11.0), (7.4, -11.0), (7.4, 11.0), (0, 5.4), (-7.4, 11.0)], [2.4, 2.4, 0.6, 0.4, 0.6], g)])]


def power(m):
    """刚启用：电源——一圈开口朝上的粗环，开口里竖一根短杠，杠与环之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    T, r = 3.0 + 1.2 * g, 9.0
    w = T
    d = math.degrees(math.asin((w / 2 + c + T / 2) / r)) + 4
    ring = bow((0, 1.6), r, -90 + d, 360 - 2 * d, T)
    stem = bar([(0, -11.2), (0, -1.6)], w)
    return [Layer("power", [ring, stem])]


def bubble_solid(m):
    """你发来消息、对 Cue 说：一只实心的对话气泡（同说了一句的那只，不挖空）。"""
    ring, _ = bubble_outline(GROW[m], 0)
    return [Layer("bubble", [ring[0]])]


def alarm(m):
    """提醒到点：闹钟——圆环钟面与指针（同排队的钟），头上左右各一只小铃（点睛），离钟面一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    T = 2.6 + 1.2 * g
    o, R = (0, 1.4), 9.4
    face = [disc(o, R + T / 2), disc(o, R - T / 2, hole=True)]
    hands = mark_hands(o, 0.72, (3.0 + 1.2 * g) / 0.72 * 0.88)
    rb = 2.5 + 0.3 * g
    bells = [disc(add(o, rot((0, -(R + T / 2 + c + rb)), k * 42)), rb) for k in (-1, 1)]
    return [Layer("clock", face + hands), Layer("bells", bells, "secondary")]


def swap(m):
    """换班次前写交接：两支发送的箭（缩小）一上一下、一左一右反着走。"""
    g, c = GROW[m], CARVE[m]
    s = 0.62
    return [Layer("a", dart(90, s, (0, -5.2))(g, c)), Layer("b", dart(-90, s, (0, 5.2))(g, c))]


def mail(m):
    """邮件：一只信封——一块圆角实心，刻出信封盖的 V 槽。"""
    g = GROW[m]
    body = grown([(-11.0, -8.4), (11.0, -8.4), (11.0, 8.4), (-11.0, 8.4)], [2.4] * 4, g)
    flap = bar([(-7.6, -4.6), (0, 1.4), (7.6, -4.6)], MARK_W(m, 2.6), [0, 2.0, 0])
    return [Layer("mail", [body] + holed([flap]))]


def face(m):
    """Cue 的档案：一张实心的圆脸，刻出两只眼（同 Cue 的竖胶囊眼）与一道笑弧。"""
    g = GROW[m]
    w = MARK_W(m, 2.6)
    eyes = [bar([(x, -4.4), (x, -1.6)], w) for x in (-3.8, 3.8)]
    smile = bow((0, 0.6), 5.2, 30, 120, w)
    return [Layer("face", [disc((0, 0), BADGE_R - 1.0 + g)] + holed(eyes + [smile]))]


def tag(m):
    """名字：一枚吊牌——右边削尖的圆角牌子，左头挖一个穿绳的孔。"""
    g = GROW[m]
    body = grown([(-11.0, -7.2), (3.6, -7.2), (11.0, 0), (3.6, 7.2), (-11.0, 7.2)], [2.2, 1.2, 1.4, 1.2, 2.2], g)
    return [Layer("tag", [body, disc((-6.4, 0), 2.0 - 0.3 * g, hole=True)])]


def shield_tick(m):
    """自动允许：一面实心的盾，刻出做完那一笔勾。"""
    g = GROW[m]
    shield = grown([(0, -11.6), (10.0, -8.0), (10.0, 0.6), (0, 11.6), (-10.0, 0.6), (-10.0, -8.0)], [1.6, 1.8, 6.0, 1.2, 6.0, 1.8], g)
    k, (cx, cy) = 0.62, (3.3, -3.2)
    tick = bar([((x - cx) * k, (y - cy) * k - 0.4) for x, y in DONE_TICK], MARK_W(m, 2.8))
    return [Layer("shield", [shield] + holed([tick]))]


def keyboard(m):
    """快捷键：一块键盘，刻出两排键与一条空格（同收起键盘那块，不带 V）。"""
    g = GROW[m]
    board = grown([(-11.0, -7.4), (11.0, -7.4), (11.0, 7.4), (-11.0, 7.4)], [2.4] * 4, g)
    k = 1.25 - 0.2 * g
    keys = [disc((x, y), k) for y in (-3.4, 0.4) for x in (-6.6, -2.2, 2.2, 6.6)]
    space = bar([(-4.4, 4.0), (4.4, 4.0)], 2 * k)
    return [Layer("board", [board] + holed(keys + [space]))]


def sun(m):
    """外观：一轮太阳——实心圆盘，外面一圈八道短光芒，各隔一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    r = 5.0 + g
    w = 2.6 + 1.0 * g
    r0 = r + c + w / 2
    rays = [bar([rot((0, -r0), k * 45), rot((0, -11.2 + w / 2), k * 45)], w) for k in range(8)]
    return [Layer("sun", [disc((0, 0), r)] + rays)]


def signal(m):
    """测试到 Mac 的连接：中间一颗点（点睛），左右各两道往外的弧，像电波。"""
    g, c = GROW[m], CARVE[m]
    w = 2.4 + 1.0 * g
    dot_ = disc((0, 0), 2.4 + 0.5 * g)
    waves = [bow((0, 0), r, side - 40, 80, w) for r in (6.2, 10.4) for side in (0, 180)]
    return [Layer("waves", waves), Layer("dot", [dot_], "secondary")]


def wave(m):
    """音频：一排高矮不一的圆头竖条（声波）。"""
    g = GROW[m]
    w = 2.6 + 1.1 * g
    xs, hs = (-9.0, -4.5, 0, 4.5, 9.0), (3.4, 7.6, 11.0, 6.0, 2.6)
    return [Layer("wave", [bar([(x, -h + w / 2), (x, h - w / 2)], w) for x, h in zip(xs, hs)])]


def cube(m):
    """转动查看：一只等轴的立方体，顶面、左面、右面三块，之间各一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    a, h = 10.4, 6.0  # 半宽、顶面半高
    top = grown([(0, -11.6), (a, -11.6 + h), (0, -11.6 + 2 * h), (-a, -11.6 + h)], [0.8, 0.8, 0.2, 0.8], g)
    d = (c + 2 * g) / math.cos(math.atan(h / a))
    mid = (0, -11.6 + 2 * h + d)
    k = c / 2 + g  # 左右两面各外扩 g 后，中间那道竖缝正好一条刻缝
    dy = k * h / a
    left_ = grown([(-a, -11.6 + h + d), (-k, mid[1] - dy), (-k, 11.6 - dy), (-a, 11.6 - h)], [0.2, 0.2, 0.8, 0.8], g)
    right_ = grown([(k, mid[1] - dy), (a, -11.6 + h + d), (a, 11.6 - h), (k, 11.6 - dy)], [0.2, 0.2, 0.8, 0.8], g)
    return [Layer("cube", [top, left_, right_])]


# ---- 项目图标（项目表单里能挑的那张闭合表，见 App 的 `ProjectIcon`）：其余几种借现成的（文件夹、闪光、终端、锤子、书、画笔、灯泡、方块）----
def bubbles(m):
    """对话：两只气泡，后面一只在左上（被前面那只挡掉一角，挡处让一条刻缝），前面一只在右下、尾巴朝右下。"""
    g, c = GROW[m], CARVE[m]
    cut = c + 2 * g  # 两块各外扩 g 后之间正好一条刻缝
    fx0, fy0 = -3.0, -2.6  # 前面那只的左上角
    back = grown([(-11.0, -10.4), (5.0, -10.4), (5.0, fy0 - cut), (fx0 - cut, fy0 - cut), (fx0 - cut, 2.6), (-6.0, 2.6), (-9.0, 5.6), (-8.6, 2.6), (-11.0, 2.6)],
                 [3.2, 3.2, 1.0, 1.2, 1.0, 0.4, 0.4, 0.4, 3.2], g)
    front = grown([(fx0, fy0), (11.0, fy0), (11.0, 7.4), (8.8, 7.4), (9.4, 10.8), (5.6, 7.4), (fx0, 7.4)], [3.2, 3.2, 3.2, 0.4, 0.4, 0.4, 3.2], g)
    return [Layer("bubbles", [back, front])]


def globe(m):
    """地球：实心圆被一条赤道、两条弯的经线刻开成六块（左右两牙、中间一枚分上下）。"""
    g, c = GROW[m], CARVE[m]
    R, A, h = 10.8 + g, 4.6, c / 2
    def mer(y): return A * math.sqrt(max(0.0, 1 - (y / R) ** 2))
    def ends(outer):  # 两牙在哪一高度与圆合上（刻缝宽 = 圆与经线的水平距），中间一枚在哪一高度收成尖
        return -R * math.sqrt(1 - (h / (R - A)) ** 2) if outer else -R * math.sqrt(1 - (h / A) ** 2)
    n = 8
    def P(x, y): return (x * G, y * G)
    def crescent(sx, sy):
        y1 = ends(True)
        ys = [-h + (y1 + h) * i / n for i in range(n + 1)]
        outer = [P(sx * math.sqrt(R * R - y * y), sy * y) for y in ys]
        inner = [P(sx * (mer(y) + h), sy * y) for y in reversed(ys)]
        segs = catmull(outer) + catmull(inner) + [Line(inner[-1], outer[0])]
        return segs if area(segs) > 0 else rev(segs)
    def lens(sy):
        y1 = ends(False)
        ys = [-h + (y1 + h) * i / n for i in range(n + 1)]
        right = [P(mer(y) - h, sy * y) for y in ys]
        left_ = [P(-(mer(y) - h), sy * y) for y in reversed(ys)]
        segs = catmull(right) + catmull(left_) + [Line(left_[-1], right[0])]
        return segs if area(segs) > 0 else rev(segs)
    return [Layer("globe", [crescent(sx, sy) for sx in (-1, 1) for sy in (1, -1)] + [lens(sy) for sy in (1, -1)])]


def target(m):
    """靶心：一圈粗环，正中一颗靶心（点睛），之间留一圈空。"""
    g = GROW[m]
    R, T = 11.0 + g * 0.5, 3.0 + 1.3 * g
    return [Layer("ring", [disc((0, 0), R), disc((0, 0), R - T, hole=True)]), Layer("bull", [disc((0, 0), 3.6 + 0.7 * g)], "secondary")]


def briefcase(m):
    """公文包：上面一道提手，包身被一条横的刻缝分成盖与身两块。"""
    g, c = GROW[m], CARVE[m]
    cut = c + 2 * g
    y0, ys, y1 = -4.6, 0.2, 10.0
    lid = grown([(-11.0, y0), (11.0, y0), (11.0, ys), (-11.0, ys)], [2.4, 2.4, 0.4, 0.4], g)
    body = grown([(-11.0, ys + cut), (11.0, ys + cut), (11.0, y1), (-11.0, y1)], [0.4, 0.4, 2.4, 2.4], g)
    w = 2.2 + 0.8 * g
    foot = y0 - g - c - w / 2
    handle = bar([(-4.6, foot), (-4.6, -11.0 + w / 2), (4.6, -11.0 + w / 2), (4.6, foot)], w, 1.6)
    return [Layer("case", [lid, body, handle])]


def cart(m):
    """购物车：左上一段把手连着往右撑开的筐，筐下两只轮子，离筐一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    w = 2.4 + 1.0 * g
    basket = grown([(-7.4, -6.4), (11.0, -6.4), (8.6, 3.0), (-5.2, 3.0)], [0.6, 1.2, 1.2, 0.6], g)
    handle = bar([(-11.0, -10.0), (-8.4, -10.0), (-6.4, -4.0)], w, 2.2)
    r = 2.2 + 0.5 * g
    y = 3.0 + g + c + r
    return [Layer("cart", [basket, handle, disc((-3.6, y), r), disc((7.0, y), r)])]


def megaphone(m):
    """喇叭：往右张开的喇叭筒，左边一截握把，之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    cut = c + 2 * g
    x = -4.4
    horn = grown([(x, -3.8), (10.6, -10.4), (10.6, 10.4), (x, 3.8)], [0.6, 1.6, 1.6, 0.6], g)
    grip = grown([(-11.0, -3.8), (x - cut, -3.8), (x - cut, 3.8), (-11.0, 3.8)], [1.4, 0.4, 0.4, 1.4], g)
    return [Layer("megaphone", [horn, grip])]


def flag(m):
    """旗帜：一根旗杆，右边一面燕尾旗，离杆一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    w = 2.6 + 1.1 * g
    x = -8.2
    pole = bar([(x, -10.6), (x, 11.0 - w / 2)], w)
    x0 = x + w / 2 + c + g
    cloth = grown([(x0, -10.6), (10.8, -10.6), (6.2, -4.2), (10.8, 2.2), (x0, 2.2)], [0.4, 0.6, 0.6, 0.6, 0.4], g)
    return [Layer("flag", [pole, cloth])]


def leaf(m):
    """叶子：两道弧合成的叶片斜放，刻出一道叶脉，左下伸出一截叶柄。"""
    g = GROW[m]
    a, b = (-5.6, 5.6), (10.6, -10.6)
    L = dist(a, b)
    bulge = 7.4 + g  # 叶片最宽处的半宽
    r = (L * L / 4 + bulge * bulge) / (2 * bulge)
    mid, u = mul(add(a, b), 0.5), norm(sub(b, a))
    n_ = left(u)
    a_, b_ = sub(a, mul(u, g)), add(b, mul(u, g))
    def side(sgn):
        c_ = add(mid, mul(n_, -sgn * (r - bulge)))
        a0, a1 = ang(sub(a_, c_)), ang(sub(b_, c_))
        sw = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        return Arc(mul(c_, G), r * G, a0, sw, 2)
    s1, s2 = side(1), side(-1)
    blade = [s1, reverse(s2)]
    blade = blade if area(blade) > 0 else rev(blade)
    w = MARK_W(m, 2.2)
    vein = bar([add(a, mul(u, 4.0)), add(b, mul(u, -4.4))], w)
    stem = bar([add(a, mul(u, 2.0)), add(a, mul(u, -4.6))], 2.4 + 1.0 * g)
    return [Layer("leaf", [blade] + holed([vein]) + [stem])]


def menubar(m):
    """菜单栏里的 CuePad（同 logo）：一圈往右开口的粗 C，开口里嵌一张折角的小纸。只在菜单栏用，单色模板图。"""
    g, c = GROW[m], CARVE[m]
    T = 4.2 + 1.4 * g
    ring = bow((-3.2, 0), 8.0 - T / 2, 45, 270, T)
    x0, y0, x1, y1 = 5.2, -3.6, 11.2, 4.6
    e = 2.8
    paper_ = grown([(x0, y0), (x1 - e, y0), (x1, y0 + e), (x1, y1), (x0, y1)], [1.0, 0.2, 0.2, 1.0, 1.0], g)
    return [Layer("mark", [ring, paper_])]


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
    "waiting": badge(mark_question),
    "failure": badge(mark_exclaim),
    "undelivered": badge(mark_uturn),
    "unknown": badge(mark_question, solid=False),
    "picked": picked,
    "asking": bubble_question,
    "ended": ring_slash,
    "interrupted": bolt_cut,
    "cursor": cursor,
    "sparkle": sparkle,
    "agent": sparkles,
    "reload": lambda m: circle_arrow(m, 1),
    "renew": lambda m: circle_arrow(m, 2),
    "cloud": cloud(),
    "cloud.done": cloud(mark_tick),
    "cloud.sync": cloud(mark_cycle, 0.6),
    "cloud.alert": cloud(mark_exclaim),
    "cloud.pause": cloud(mark_pause, 0.56),
    "cloud.up": cloud(mark_arrow),
    "cloud.down": cloud(lambda c, s, w: mark_arrow(c, s, w, down=True)),
    "cloud.off": cloud_slash,
    "cloud.lock": cloud_lock,
    "bell": bell,
    "bell.on": bell_on,
    "bell.off": bell_off,
    "reopen": ring_mark(mark_uturn),
    "restore": restore,
    "play": play,
    "indent": indent(1),
    "outdent": indent(-1),
    "link": chain(True),
    "unlink": chain(False),
    "folder": folder(),
    "folder.add": folder(mark_plus),
    "folder.remove": folder(mark_minus),
    "folder.missing": folder(lambda c, s, w: mark_question(c, s * 0.8, w)),
    "books": books,
    "pin": pin,
    "unpin": unpin,
    "copy": sheets(True),
    "conflict": sheets(False),
    "deck": deck,
    "stack": stack,
    "grid": grid,
    "share": tray_arrow(True),
    "save": tray_arrow(False),
    "pencil": pencil,
    "write": write,
    "choose": choose,
    "filter": filter_lines,
    "puzzle": puzzle,
    "tick": tick,
    "plane": plane,
    "plane.done": plane_done,
    "bolt": bolt,
    "clock": ring_mark(mark_hands),
    "arrow.down": arrow_down,
    "ring.down": ring_mark(lambda c, s, w: mark_arrow(c, s, w, down=True)),
    "ring.stop": ring_mark(mark_square),
    "ring.play": ring_mark(mark_play),
    "ring.plus": ring_mark(mark_plus),
    "badge.up": badge_dart(0),
    "badge.down": badge_dart(180),
    "compact": compact,
    "hand": hand,
    "mac": mac,
    "photo": photo,
    "photos": photos,
    "camera": camera,
    "select": select_text,
    "keyboard.down": keyboard_down,
    "braces": braces,
    "terminal": terminal,
    "window": window,
    "doc": paper(paper_lines),
    "doc.blank": paper(),
    "wrench": wrench,
    "bubble.text": bubble("text"),
    "bubble.dots": bubble("dots"),
    "branch": branch,
    "dot": dot,
    "flame": flame,
    "hammer": hammer,
    "layers": layers3,
    "brush": brush,
    "eye": eye,
    "person": person,
    "bookmark": bookmark,
    "power": power,
    "bubble": bubble_solid,
    "alarm": alarm,
    "swap": swap,
    "mail": mail,
    "face": face,
    "tag": tag,
    "shield.tick": shield_tick,
    "keyboard": keyboard,
    "sun": sun,
    "signal": signal,
    "wave": wave,
    "cube": cube,
    "bubbles": bubbles,
    "globe": globe,
    "target": target,
    "briefcase": briefcase,
    "cart": cart,
    "megaphone": megaphone,
    "flag": flag,
    "leaf": leaf,
    "menubar": menubar,
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
    accent = sum(a for a, L in zip(ink, layers) if L.tier == "secondary" and not L.ground)
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
