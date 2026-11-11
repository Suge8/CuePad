"""项目选择器的 22 个轮廓符号；中线交给共享几何生成等宽轮廓。"""
import math

from ink.geometry import Arc, Line, arcs, disc, poly, rot

NAMES = (
    "sparkle", "bubbles", "terminal", "globe", "hammer", "books", "target",
    "briefcase", "cart", "brush", "flag", "cube", "leaf", "layers", "camera",
    "house", "heart", "star", "music", "rocket", "bolt", "megaphone",
)


def centerlines(name):
    opened, closed = [], []
    def line(*points, radius=0): opened.append(poly(points, radius))
    def loop(points, radius=0): closed.append(poly(points, radius, closed=True))
    def box(x, y, a, b, radius=2.5): loop([(x,y),(a,y),(a,b),(x,b)], radius)
    def circle(x, y, r): closed.append(arcs((x,y),r,-90,360))

    if name == "sparkle":
        loop([(0,-11),(3,-3),(11,0),(3,3),(0,11),(-3,3),(-11,0),(-3,-3)], 1.6)
    elif name == "bubbles":
        loop([(-2,-2),(10,-2),(10,10),(6,7),(-2,7)], [2.2,2.2,1.6,1.6,2.2])
        line((-6,5),(-10,8),(-10,-9),(6,-9),(6,-6),radius=2)
    elif name == "terminal":
        box(-10,-8,10,8,3)
        line((-5,-3),(-2,0),(-5,3)); line((2,3),(5,3))
    elif name == "globe":
        circle(0,0,10)
        line((-10,0),(10,0))
        angle = math.degrees(math.acos(10/14))
        opened.extend([arcs((-10,0),14,-angle,angle*2),
                       arcs((10,0),14,180-angle,angle*2)])
    elif name == "hammer":
        loop([(-2,-11),(8,-6),(5,-1),(-5,-6)], 1.7)
        line((-1,-2),(-8,10))
    elif name == "books":
        box(-10,-9,-4,9,1.8)
        box(0,-9,6,9,1.8)
        line((-9,4),(-5,4)); line((1,4),(5,4))
        line((9,-7),(11,8))
    elif name == "target":
        circle(0,0,10); circle(0,0,5)
    elif name == "briefcase":
        box(-10,-5,10,9,2.5)
        line((-4,-5),(-4,-10),(4,-10),(4,-5),radius=1.8)
        line((-10,1),(10,1)); line((0,-1),(0,3))
    elif name == "cart":
        line((-11,-9),(-7,-9),(-4,5),(8,5),radius=1.6)
        line((-6,-5),(11,-5),(8,2),(-4.6,2),radius=1.6)
    elif name == "brush":
        loop([(-3,2),(6,-10),(10,-6),(1,6)], 1.6)
        loop([(-5,3),(1,7),(-4,11),(-10,10)], 1.6)
    elif name == "flag":
        line((-9,10),(-9,-10))
        line((-9,-9),(9,-9),(6,-3),(9,3),(-9,3),radius=1.6)
    elif name == "cube":
        loop([(0,-10),(9,-5),(9,6),(0,11),(-9,6),(-9,-5)], 1.6)
        line((-9,-5),(0,0),(9,-5)); line((0,0),(0,10))
    elif name == "leaf":
        loop([(-7,8),(-9,-3),(9,-10),(8,4)], [4,4,2,4])
        line((-10,11),(4,-4))
    elif name == "layers":
        loop([(0,-10),(10,-4),(0,2),(-10,-4)], 1.6)
        line((-10,1),(0,7),(10,1),radius=1.6)
        line((-10,6),(0,12),(10,6),radius=1.6)
    elif name == "camera":
        loop([(-10,-5),(-5,-5),(-3,-9),(3,-9),(5,-5),(10,-5),(10,9),(-10,9)], 1.6)
        circle(0,2,4)
    elif name == "house":
        line((-11,0),(0,-10),(11,0),radius=1.8)
        line((-8,-2),(-8,10),(8,10),(8,-2),radius=2.5)
        line((-3,10),(-3,3),(3,3),(3,10),radius=1.8)
    elif name == "heart":
        loop([(0,-4),(-4,-8),(-9,-6),(-10,-1),(0,10),(10,-1),(9,-6),(4,-8)],
             [1.6,3,3,3,1.6,3,3,3])
    elif name == "star":
        points = []
        for i in range(10):
            angle = math.radians(-90+i*36)
            r = 11 if i%2 == 0 else 5.5
            points.append((r*math.cos(angle),r*math.sin(angle)+.5))
        loop(points,1.6)
    elif name == "music":
        line((-3,7),(-3,-7),(9,-10),(9,4),radius=1.6)
    elif name == "rocket":
        # 朝右上；简单舷窗与双翼，不把微小火焰挤进轮廓。
        body = poly([(0,-12),(5,-5),(5,6),(-5,6),(-5,-5)], [2,2.5,1.6,1.6,2.5],closed=True)
        def turn(path):
            return [Line(rot(s.a,45),rot(s.b,45)) if isinstance(s,Line)
                    else Arc(rot(s.c,45),s.r,s.a0+math.pi/4,s.sweep,s.pieces) for s in path]
        closed.append(turn(body))
        closed.append(turn(arcs((0,-3),2.2,-90,360)))
        opened.append(turn(poly([(-5,0),(-9,5),(-9,9),(-5,6)],1.6)))
        opened.append(turn(poly([(5,0),(9,5),(9,9),(5,6)],1.6)))
        opened.append(turn(poly([(-2,10),(0,13),(2,10)],1.6)))
    elif name == "bolt":
        loop([(2,-11),(-9,2),(-1,2),(-2,11),(9,-2),(1,-2)], 1.6)
    elif name == "megaphone":
        loop([(-9,-4),(-3,-4),(10,-10),(10,8),(-3,2),(-9,2)], 1.6)
        line((-5,3),(-3,10),(1,10),radius=1.6)
    else:
        raise ValueError(f"Unknown project icon: {name}")
    return opened, closed


def fills(name, w):
    if name == "target": return [disc((0,0),w*.65)]
    if name == "cart": return [disc((x,10),w*.65) for x in (-3,7)]
    if name == "music": return [disc((-6,7),3+(w-2.4)/2), disc((6,4),3+(w-2.4)/2)]
    return []
