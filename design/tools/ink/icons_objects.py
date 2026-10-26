"""会话里的物件：气泡、Mac 与窗口、纸、工具、相片、键盘、角色几族。"""
from __future__ import annotations

from .icons_send import *

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

