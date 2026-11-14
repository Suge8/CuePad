"""图标几何：唯一线宽、真圆角中线、开放圆帽与闭合双偏移。"""
import math
from ink.geometry import G, Arc, Line, _side, add, ang, area, left, mul, poly, rev, rot, stroke, sub

WIDTH = {"Ultralight": 1.7, "Regular": 2.4, "Black": 3.0}


def box(x, y, a, b, radius=3):
    return poly([(x,y),(a,y),(a,b),(x,b)],radius,closed=True)


def moved(path, x=0, y=0, angle=0):
    def point(p):
        a,b = rot(p,angle)
        return a+x*G,b+y*G
    return [Line(point(s.a),point(s.b)) if isinstance(s,Line)
            else Arc(point(s.c),s.r,s.a0+math.radians(angle),s.sweep,s.pieces) for s in path]


def closed_stroke(segs, width):
    """闭环两侧精确偏移，不加端帽；把接缝放在直段内部避免漏接拐角。"""
    if isinstance(segs[0], Line):
        first = segs[0]
        mid = tuple((a+b)/2 for a,b in zip(first.a,first.b))
        segs = [Line(mid,first.b)] + segs[1:] + [Line(first.a,mid)]
    sides = [_side(segs,width*G/2), _side(segs,-width*G/2)]
    outer, inner = sorted(sides,key=lambda s: abs(area(s)),reverse=True)
    return [outer if area(outer)>0 else rev(outer), inner if area(inner)<0 else rev(inner)]



def contours(opened, closed, width):
    result = [stroke(path,width*G) for path in opened]
    for path in closed: result.extend(closed_stroke(path,width))
    return result



def arrow(segs, width, head):
    """一笔带箭镞（模板单位）：尾端圆头，头端是三角箭镞；head=(镞长, 镞半宽)。"""
    h, (hl, hw) = width / 2, head
    L, R = _side(segs, h), _side(segs, -h)
    P1, t, P0 = segs[-1].end(), segs[-1].dir1(), segs[0].start()
    n = left(t)
    a, tip, b = add(P1, mul(n, hw)), add(P1, mul(t, hl)), sub(P1, mul(n, hw))
    c = L + [Line(L[-1].end(), a), Line(a, tip), Line(tip, b), Line(b, R[-1].end())] + rev(R) + [Arc(P0, h, ang(left(segs[0].dir0())) + math.pi, math.pi)]
    return c if area(c) > 0 else rev(c)


def ring(c, r, a0, a1, step=20):
    """圆上从 a0 到 a1 度（y 朝下，角度增大是顺时针）的一串点（格），给 `smooth` 把弧拆成折线再倒成圆角。"""
    n = max(2, math.ceil(abs(a1 - a0) / step))
    return [(c[0] + r * math.cos(math.radians(a0 + (a1 - a0) * k / n)), c[1] + r * math.sin(math.radians(a0 + (a1 - a0) * k / n))) for k in range(n + 1)]


def smooth(points, radii, closed=False):
    """折线每个拐角倒圆角，圆角大到放不下时按两边的段长等比收小：大弧拆成折线、各拐角给接近内切圆的圆角，
    整条中线全由相切的线与弧组成（圆弧与相邻段必须相切，`verify-symbols.py` 查）。几乎共线的拐角不倒；
    收小到 `SHARP` 以下的改成尖角：圆角比最粗母版的半线宽小时描边内侧会翻折，尖角的外侧描边本来就是圆的。"""
    n = len(points)
    def turn(i):
        a, b, c = points[i - 1], points[i], points[(i + 1) % n]
        u, v = (a[0] - b[0], a[1] - b[1]), (c[0] - b[0], c[1] - b[1])
        cos = (u[0] * v[0] + u[1] * v[1]) / math.hypot(*u) / math.hypot(*v)
        return math.acos(max(-1, min(1, cos)))
    corners = range(n) if closed else range(1, n - 1)
    radii = [r if i in corners and turn(i) < math.pi - 1e-3 else 0 for i, r in enumerate(radii)]
    reach = [r / math.tan(turn(i) / 2) if r else 0 for i, r in enumerate(radii)]
    for i in range(n if closed else n - 1):
        j = (i + 1) % n
        length = math.dist(points[i], points[j])
        if reach[i] + reach[j] > length * 0.96:
            k = length * 0.96 / (reach[i] + reach[j])
            radii[i] *= k; radii[j] *= k; reach[i] *= k; reach[j] *= k
    return poly(points, [r if r >= SHARP else 0 for r in radii], closed)


SHARP = 1.6
