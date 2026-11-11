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
