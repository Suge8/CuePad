"""墨块的几何：网格与字重常量、直线圆弧三次曲线组成的闭合轮廓、圆头的一笔、基本形、裁切与分层（`Layer`）。"""
from __future__ import annotations

import math
from dataclasses import dataclass

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
