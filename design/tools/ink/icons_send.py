"""输入与发送：纸飞机、胖箭头、圆环里的记号。"""
from __future__ import annotations

from .icons_actions import *

# ---------- 输入、发送与会话：纸飞机、箭头、圆环记号、气泡、窗口、相片、角色几族 ----------

# 机头、左翼尖、折痕底、下翼尖（格）；三角的墨比方块少，同气泡一样放大 K。
# 按面积重心摆在正中（不按外框）：机身的墨全在右上，按外框摆看着偏右上。
_PLANE = [(11.0, -10.4), (-11.0, -0.6), (-2.6, 2.8), (0.6, 11.0)]
_PLANE_MASS = (1.05, -0.82)
PLANE = sc(K, [sub(p, _PLANE_MASS) for p in _PLANE])


def plane_parts(g, c, s=1.0, at=(0.0, 0.0)):
    """纸飞机（格）：机头朝右上，一道直刀口的折痕从机头斜下来，把机身切成上翼与下翼两块；s 缩放、挪到 at，刀口不随着缩。"""
    nose, wing, fold, tail = [add(mul(p, s), at) for p in PLANE]
    k = c + 2 * g  # 两翼各外扩 g 之后正好一条刻缝
    n = left(norm(sub(fold, nose)))
    n = n if (tail[0] - nose[0]) * n[0] + (tail[1] - nose[1]) * n[1] > 0 else mul(n, -1)
    a, b = add(nose, mul(n, k)), add(fold, mul(n, k))
    upper = grown([fold, wing, nose], [0.9 * s, 1.0 * s, 0.9 * s], g)
    lower = grown([tail, meet(a, b, fold, tail), meet(a, b, nose, tail)], [1.0 * s, 0.9 * s, 0.9 * s], g)
    return upper, lower


def plane(m):
    """发出（发送钮、发送回答）与交给（转交给 Cue、会话里转给别人的那一步）：一架纸飞机。"发出"一族都是这一份几何。
    两块都在主层，分两层只为按层动效（上翼、下翼依次一跳）。"""
    upper, lower = plane_parts(GROW[m] * 0.6, CARVE[m])
    return [Layer("upper", [upper]), Layer("lower", [lower])]


def meet(p1, p2, q1, q2):
    """两条直线（各过两点）的交点。"""
    d1, d2 = sub(p2, p1), sub(q2, q1)
    t = cross(sub(q1, p1), d2) / cross(d1, d2)
    return add(p1, mul(d1, t))


def plane_done(m):
    """已送达：纸飞机（同交给），右下的空角里嵌一个小勾（点睛），离飞机一条刻缝。"""
    g = GROW[m]
    tick = bar([(8.0, 10.4), (10.2, 12.6), (14.6, 8.0)], 2.4 + 1.0 * g)
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


def pointing(deg):
    """只表示方向的箭：胖箭头朝上（在上面、拿回来的、更早的）或朝下（回到最新）。"""
    return lambda m: [Layer("arrow", [fat_arrow(GROW[m], deg)])]


def compact(m):
    """压缩上下文：两支胖箭头（缩小）从左上、右下往中间收，箭尖之间隔一道缝。"""
    g = GROW[m] * 0.8
    s, tip = 0.72, 1.0  # 箭尖离中心多少格（沿对角线的分量）
    d = tip + FAT_ARROW[0][1] * -s * 0.7071
    return [Layer("a", [fat_arrow(g, 135, s, (-d, -d))]), Layer("b", [fat_arrow(g, -45, s, (d, d))])]


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
