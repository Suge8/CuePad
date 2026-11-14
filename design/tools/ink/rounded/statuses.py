"""状态图标：等你用独立裸问号，失败保留实心标，交付与同步保持不同语义。"""
import math
from ink.geometry import G, Layer, arcs, disc, poly, rev
from .shared import arrow
from . import base
from .shared import box, contours, ring, smooth

NAMES = (
    "waiting", "failure", "undelivered", "unknown", "question", "picked", "asking", "ended", "gone", "interrupted", "turn", "spring",
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


def fillet(r, step=20):
    """拆成折线的圆弧，每个拐角的圆角：接近折线的内切圆，倒完仍是一段圆弧（`smooth`）。"""
    return 0.97 * r * math.cos(math.radians(step / 2))


def bot(eyes):
    """方脑袋小机器人（等子代理）：头、天线、两只耳朵、两只眼睛。"""
    lines = [box(-8,-4,8,8,3)], [poly([(0,-4),(0,-8),(-4,-8)],1.6), poly([(-10.4,2),(-8,2)]), poly([(8,2),(10.4,2)])]
    return lines[1] + eyes, lines[0]


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
        # 收工了：一弯月牙。外圆与内圆（偏右上）各拆成折线倒圆角，两个尖收成小圆头
        outer, inner = ring((0,0),9,3.1,266.9), ring((5.4,-5),6,212,58,19)
        closed.append(smooth(outer + inner, [0] + [fillet(9)] * (len(outer) - 2) + [0, 0] + [fillet(6,19)] * (len(inner) - 2) + [0], True))
    elif name == "gone":
        # 那一处已经没有了：断开的圈加一道斜线
        opened.extend([arcs((0,0),9,65,140),arcs((0,0),9,245,140)])
        line((-7,-7),(7,7))
    elif name == "interrupted":
        # 拔掉的插头：做到一半进程没了，说一句就插回去接着做。两半各一根线，插头那半带两根插脚
        closed.append(smooth([(0,6),(-6,0),(-10,4),(-4,10)],[0,0,2.4,2.4],True))
        closed.append(smooth([(0,-6),(6,0),(10,-4),(4,-10)],[0,0,2.4,2.4],True))
        line((-4.5,1.5),(-2,-1)); line((-1.5,4.5),(1,2))
        line((-10,10),(-7,7)); line((7,-7),(10,-10))
    elif name == "turn":
        # 该你了：圆气泡里一支往回拐的箭头（回复）
        rim = ring((0,0),9.4,154,474.9)
        closed.append(smooth(rim + [(-9.6,9.6)], [1.6] + [fillet(9.4)] * (len(rim) - 2) + [1.6, 1.6], True))
        line((-2,-3),(-5,0),(-2,3)); line((-5,0),(5,0),(5,3.4),radius=2)
    elif name == "spring":
        # 压缩上下文：两块板夹着一段弹簧
        line((-10.6,-7),(-10.6,7)); line((10.6,-7),(10.6,7))
        # 四段一上一下的圆弧首尾相切，每段比半圆多鼓出一点（像弹簧圈）。不用折线倒角：峰一尖，圆角就放不下最粗母版的线宽
        r, bulge = 2.0, 120
        span = 2 * r * math.sin(math.radians(bulge))
        coil = []
        for k in range(4):
            up = -1 if k % 2 == 0 else 1
            centre = (-2 * span + (k + 0.5) * span, up * -r * math.cos(math.radians(bulge)))
            coil += arcs(centre, r, -90 - bulge, 2 * bulge) if up < 0 else arcs(centre, r, 90 + bulge, -2 * bulge)
        opened.append(coil)
    elif name in ("relay", "relay.stalled"):
        # 等子代理：一个方脑袋小机器人；卡住了的那只眼睛是两道横线
        eyes = [poly([(-3,1),(-3,3)]), poly([(3,1),(3,3)])] if name == "relay" else [poly([(-4.2,2),(-1.8,2)]), poly([(1.8,2),(4.2,2)])]
        o, c = bot(eyes); opened.extend(o); closed.extend(c)
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
