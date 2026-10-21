"""主图标：吉祥物、灵感、任务、会话、搜索、设置、归档、回收站、侧栏与几个基本操作、做完。"""
from __future__ import annotations

from .geometry import *

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


def dart_parts(g, c, s=1.0):
    """燕尾箭（格，朝上）：一枚高而尖的箭镞，底边往里凹成 V；箭杆顶削成同角度的尖插在 V 里，中间一道等宽刀口。
    s 按比例缩放整支，刀口不随着缩，每档仍是一条刻缝（两块各外扩 g：刀口预留 2g，外扩后正好是这一档的刻缝）。
    只表示方向的一族（在上面、拿回来的、更早的、回到最新、压缩上下文、自动检查更新）都是这一支（`dart`）；"发出"是纸飞机（`plane`）。"""
    k, notch, bx = 0.75, -1.6 * s, 7.6 * s  # V 的斜率、谷底、两翼半宽
    cut = (c + 2 * g) / math.cos(math.atan(k))
    head = grown([(0, -12.0 * s), (bx, notch + bx * k), (0, notch), (-bx, notch + bx * k)], [0.5, 0.45, 0, 0.45], g)
    w, top = 2.4 * s, notch + cut
    shaft = grown([(0, top), (w, top + w * k), (w, 11.4 * s), (-w, 11.4 * s), (-w, top + w * k)], [0, 0, 1.0, 1.0, 0], g)
    return shaft, head


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
