"""状态图标：等你用独立裸问号，失败保留实心标，交付与同步保持不同语义。"""
import math
from ink.geometry import G, Layer, arcs, disc, poly, rev
from .shared import arrow
from . import base
from .shared import box, contours

NAMES = (
    "waiting", "failure", "undelivered", "unknown", "question", "picked", "asking", "ended", "interrupted",
    "relay", "relay.stalled", "cursor", "agent", "reload", "cloud", "cloud.done", "cloud.sync", "cloud.alert",
    "cloud.pause", "cloud.up", "cloud.down", "cloud.off", "cloud.lock", "bell", "bell.on", "bell.off", "cold",
)


def question():
    return arcs((.5,-3),4.2,180,270) + arcs((.5,3.6),2.4,-90,-90)


def cloud():
    """三颗圆云瓣，以半径 2 的内凹圆弧相切连接；底边是唯一平直段。"""
    # 主瓣 r9、小瓣 r5；内凹过渡圆心是半径11和7两圆的上方交点。
    dx,dy = 8,5
    distance = math.hypot(dx,dy)
    along = (11**2-7**2+distance**2)/(2*distance)
    height = math.sqrt(11**2-along**2)
    x = dx/distance*along + dy/distance*height
    y = -2 + dy/distance*along - dx/distance*height
    big = math.degrees(math.atan2(y+2,x))
    small = math.degrees(math.atan2(y-3,x-8))
    return (arcs((-8,3),5,90,90-small)
            + arcs((-x,y),2,-small,small-big)
            + arcs((0,-2),9,180-big,180+2*big)
            + arcs((x,y),2,180+big,small-big)
            + arcs((8,3),5,small,90-small)
            + poly([(8,8),(-8,8)]))


def centerlines(name):
    opened,closed = [],[]
    def line(*points,radius=0): opened.append(poly(points,radius))
    def circle(x,y,r): closed.append(arcs((x,y),r,-90,360))
    if name in ("waiting","unknown","question","asking"):
        opened.append(question() if name in ("waiting","question") else arcs((.9,-3),2.8,180,270) + arcs((.9,1.6),1.8,-90,-90))
        if name == "unknown": circle(0,0,10)
        elif name == "asking":
            closed.append(poly([(-11,-10),(11,-10),(11,8),(-3,8),(-11,12)],[3.5,3.5,3.5,1.8,2],True))
    elif name == "failure": line((0,-6),(0,1))
    elif name == "undelivered":
        opened.append(poly([(-3,4.6),(1.6,4.6)]) + arcs((1.6,.8),3.8,90,-180) + poly([(1.6,-3),(-1.4,-3)]))
    elif name == "picked": line((-5,0),(-1,4),(6,-4))
    elif name == "ended":
        # 终点站：会话那根线放平、走到头是一个圈（线路图的终点，也是画上句号）；状态标从在跑的线连续变过来（`StateInk`）
        line((-10,0),(-2,0)); circle(5.5,0,4)
    elif name == "interrupted": line((-10,2),(-3,2)); line((3,-2),(10,-2))
    elif name == "relay": pass
    elif name == "relay.stalled": circle(7.2,-7.2,3.9)
    elif name == "cursor":
        line((-10,0),(-4,0)); line((1,-9),(9,-9)); line((5,-9),(5,9)); line((1,9),(9,9))
    elif name == "agent": pass
    elif name == "reload":
        opened.append(arcs((0,0),8.5,-10,300))
    elif name.startswith("cloud"):
        closed.append(cloud())
        mark = name.partition(".")[2]
        if mark == "done": line((-4,0),(-1,3),(3.5,-3))
        elif mark == "sync":
            opened.append(arcs((0,-1),3.4,-50,290))
        elif mark == "alert": line((0,-5),(0,-1))
        elif mark == "pause": line((-3,-3),(-3,2)); line((3,-3),(3,2))
        elif mark in ("up","down"):
            d = 1 if mark == "down" else -1
            line((0,-d*3),(0,d*3)); line((-3,0),(0,d*3),(3,0))
        elif mark == "off": line((-12,-10),(12,11))
        elif mark == "lock":
            closed.append(box(-3.5,-2,3.5,3,1.6)); opened.append(arcs((0,-2),2.3,180,180))
    elif name.startswith("bell"):
        # 单根中线由铃肩到外摆；顶端圆弧与竖边真正相切。
        body = arcs((0,-3),6,180,180) + poly([(6,-3),(6,3),(9,6),(-9,6),(-6,3),(-6,-3)],0)
        closed.append(body)
        opened.append(arcs((0,7),3,20,140))
        if name == "bell.on":
            opened.extend([arcs((0,-3),11,190,40),arcs((0,-3),11,-50,40)])
        elif name == "bell.off": line((-10,-10),(10,10))
    elif name == "cold":
        # 雪花：三根过心的杆，六个杆头各一对朝外的短枝；枝只画在杆的外半截，缩到小字号时心里不糊成一团。
        def at(radius,degrees): return (radius*math.cos(math.radians(degrees)),radius*math.sin(math.radians(degrees)))
        for degrees in (90,30,150): line(at(-10,degrees),at(10,degrees))
        for degrees in range(30,390,60):
            x,y = at(5.6,degrees)
            (a,b),(c,d) = at(3.6,degrees+52),at(3.6,degrees-52)
            line((x+a,y+b),(x,y),(x+c,y+d))
    else: raise ValueError(name)
    return opened,closed


def fills(name,w):
    if name in ("waiting","question"): return [disc((-1.9,7.6),w*.6)]
    if name in ("unknown","asking"): return [disc((-.9,5.7),w*.6)]
    if name == "failure": return [disc((0,5.5),w*.6)]
    if name == "cloud.alert": return [disc((0,3),w*.5)]
    if name == "relay": return [disc((0,0),5.28),disc((8.16,-8.16),3.12)]
    if name == "relay.stalled": return [disc((-2.2,2.2),4.7)]
    if name == "agent":
        star = base.fills("skill",w)
        return star + [disc((7,-7),w*.65),disc((-6,7),w*.65)]
    return []


def layers(name,w,ink):
    if name in ("undelivered","reload","cloud.sync"):
        path = centerlines(name)[0][0]
        length,half = (3.1,2.8) if name == "undelivered" else (2.7,2.2)
        # 箭头是一条连通轮廓，不把相交的杆/弧/箭镞分别反转后挖孔。
        ink = [arrow(path,w*G,(length*G,half*G))] + ink[1:]
    if name in ("failure","undelivered"):
        return [Layer("badge",[disc((0,0),11.8)]+[rev(c) for c in ink])]
    if name == "picked":
        opened,closed = centerlines(name)
        slot = contours(opened,closed,w+2.8)
        return [Layer("tick",ink),Layer("badge",[disc((0,0),11.8)]+[rev(c) for c in slot],"secondary",ground=True)]
    return [Layer("ink",ink)]
