"""基础图标；仅保存中线与语义实心，不写资产。"""
import math
from ink.geometry import G, Arc, Line, arcs, disc, poly, rot, rpoly

NAMES = (
    "idea", "task", "session", "folder", "bookmark", "skill", "search", "filter", "plus", "close", "more", "plane", "sidebar", "copy", "trash", "archive", "clip", "alarm", "done", "dot", "stop", "play", "renew", "doc", "bubble", "folder.add",
)

def centerlines(kind):
    """返回开放、闭合中线；圆角为相切圆弧，三个母版共享同一条中线。"""
    opened, closed = [], []
    def line(*points, radius=0): opened.append(poly(points, radius))
    def loop(points, radius): closed.append(poly(points, radius, closed=True))
    def box(x, y, a, b, radius): loop([(x,y),(a,y),(a,b),(x,b)], radius)
    def circle(x, y, r): closed.append(arcs((x,y),r,-90,360))
    if kind == "idea":
        head = arcs((0,-3),7,135,270)
        right = tuple(v/G for v in head[-1].end())
        left = tuple(v/G for v in head[0].start())
        neck_y = right[1] + right[0] - 3.5
        neck = poly([right,(3.5,neck_y),(3.5,6),(-3.5,6),(-3.5,neck_y),left],1.6)
        closed.append(head + neck)
        line((-2.1,10.4),(2.1,10.4))
    elif kind in ("folder", "folder.add"):
        loop([(-10,-6),(-5,-6),(-2,-3),(10,-3),(10,9),(-10,9)], [2.5,1.8,1.8,2.5,3,3])
        if kind == "folder.add":
            line((-3,3),(3,3)); line((0,0),(0,6))
    elif kind == "bookmark":
        loop([(-7,-9),(7,-9),(7,9),(0,5.5),(-7,9)], [3,3,1.7,1.7,1.7])
    elif kind == "doc":
        loop([(-8,-10),(1,-10),(8,-3),(8,10),(-8,10)], [3,1.8,1.8,3,3])
        line((-3,4),(3,4))
    elif kind == "bubble":
        loop([(-9,-8),(9,-8),(9,6),(-3,6),(-9,10)], [3.5,3.5,3.5,1.8,2])
    elif kind == "sidebar":
        box(-10,-8.5,10,8.5,3.3)
        line((-3,-8.5),(-3,8.5))
    elif kind == "skill": box(-8,-10,8,10,3.5)
    elif kind == "search":
        circle(-2,-2,6.5); line((3,3),(9,9))
    elif kind == "task":
        for y in (-7,0,7): line((-1,y),(9,y))
        line((-10,-7),(-8,-5),(-4.8,-9))
    elif kind == "session":
        line((-10,1),(-6,1),(-3,-6),(1,7),(4,1),(9,1),radius=1.6)
    elif kind == "filter":
        for x,y in ((9,-6),(5,0),(2,6)): line((-x,y),(x,y))
    elif kind == "plus":
        line((-8,0),(8,0)); line((0,-8),(0,8))
    elif kind == "close":
        line((-6,-6),(6,6)); line((6,-6),(-6,6))
    elif kind == "done": line((-8,0),(-3,5),(8,-7))
    elif kind == "plane":
        loop([(-10,-2),(9,-9),(2,10),(-1,1)], [1.6,1.6,1.6,1.6])
        line((-1,1),(5,-5))
    elif kind == "copy":
        box(-4,-5,9,10,3)
        line((1,-9),(-9,-9),(-9,3),radius=3)
    elif kind == "archive":
        box(-9,-3,9,10,3)
        line((-9.5,-7.5),(9.5,-7.5)); line((-3,2),(3,2))
    elif kind == "trash":
        loop([(-7,-4),(7,-4),(6,10),(-6,10)], 2)
        line((-9,-7.5),(9,-7.5)); line((-3,-11),(3,-11))
        line((-2.5,0),(-2.5,5)); line((2.5,0),(2.5,5))
    elif kind == "clip":
        # 两个完整 U 弯与三根长直段；平行中线间距 6，Black 仍留 3 格内白。
        path = (poly([(0,-6),(0,6)]) + arcs((-3,6),3,0,180)
                + poly([(-6,6),(-6,-6)]) + arcs((0,-6),6,180,180)
                + poly([(6,-6),(6,7)]))
        opened.append([Line(rot(s.a,45),rot(s.b,45)) if isinstance(s,Line)
                       else Arc(rot(s.c,45),s.r,s.a0+math.pi/4,s.sweep,s.pieces) for s in path])
    elif kind == "alarm":
        circle(0,1,8)
        line((0,-3.5),(0,1),(3,3))
        line((-9,-7),(-6,-9)); line((6,-9),(9,-7))
    elif kind == "renew":
        for start in (-140,40):
            arc = arcs((0,0),8,start,125)
            opened.append(arc)
            p = tuple(v/G for v in arc[-1].end())
            t = arc[-1].dir1(); n = (-t[1],t[0])
            line((p[0]-3*t[0]+2.4*n[0],p[1]-3*t[1]+2.4*n[1]),p,
                 (p[0]-3*t[0]-2.4*n[0],p[1]-3*t[1]-2.4*n[1]))
    elif kind not in ("more", "dot", "stop", "play"):
        raise ValueError(f"Unknown icon: {kind}")
    return opened, closed


def fills(kind, w):
    cs = []
    # 点、媒体控制和技能星是实心语义，不伪装成等宽线；体量随母版变化。
    dots = {"task": [(-8,0),(-8,7)], "bubble": [(-3,-1),(3,-1)],
            "more": [(-7,0),(0,0),(7,0)]}
    for point in dots.get(kind,[]): cs.append(disc(point,w*.6))
    if kind == "dot":
        # 待回复是状态圆点，不是标点；保留原图标 Regular 的可见体量。
        cs.append(disc((0,0),6.6+(w-2.4)/2))
    elif kind == "stop":
        r = 6.5 + (w-2.4)/2
        cs.append(rpoly([(-r,-r),(r,-r),(r,r),(-r,r)],[2.5]*4))
    elif kind == "play":
        s = 1+(w-2.4)/14
        cs.append(rpoly([(x*s,y*s) for x,y in [(-6,-9),(9,0),(-6,9)]],[1.5]*3))
    elif kind == "skill":
        s = 1+(w-2.4)/10
        points = [(0,-5),(1.5,-1.5),(5,0),(1.5,1.5),(0,5),(-1.5,1.5),(-5,0),(-1.5,-1.5)]
        cs.append(rpoly([(x*s,y*s) for x,y in points],[.35]*8))
    return cs
