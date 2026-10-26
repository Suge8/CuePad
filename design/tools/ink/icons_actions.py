"""动作与菜单图标（任务与卡片操作、导航入口）：一族一份几何。"""
from __future__ import annotations

from .icons_status import *

# ---------- 动作与菜单（任务与卡片操作、导航入口）：一族一份几何 ----------

def turned(contours, deg):
    """整组轮廓（模板单位）绕原点转 deg 度：直线转端点，圆弧转圆心与起角，曲线转控制点。"""
    def t(p): return rot(p, deg)
    def seg(s):
        if isinstance(s, Line): return Line(t(s.a), t(s.b))
        if isinstance(s, Cubic): return Cubic(t(s.p0), t(s.p1), t(s.p2), t(s.p3))
        return Arc(t(s.c), s.r, s.a0 + math.radians(deg), s.sweep, s.pieces)
    return [[seg(s) for s in c] for c in contours]


def ring_mark(mark, scale=0.88):
    """圆环里嵌一个记号（同"未知"的圆标）：完成（勾）、重新打开（往回折的箭头）。"""
    def build(m):
        g = GROW[m]
        T = 2.6 + 1.2 * g
        return [Layer("ring", [disc((0, 0), 11.6 + T / 2), disc((0, 0), 11.6 - T / 2, hole=True)]),
                Layer("mark", mark((0, 0.3), scale, (3.0 + 1.2 * g) / scale * 0.88))]
    return build


def restore(m):
    """取回、恢复：一支往回折的粗箭头（同没能送达里刻的那支），不带圆。"""
    s = 1.75
    return [Layer("arrow", mark_uturn((0.4, 0.2), s, (2.9 + 1.2 * GROW[m]) / s))]


def play(m):
    """开始：一块圆角的实心三角，重心落在图形中心。"""
    g = GROW[m]
    return [Layer("play", [grown([(-6.0, -10.6), (10.8, 0), (-6.0, 10.6)], [2.4, 2.0, 2.4], g)])]


def indent(direction):
    """缩进 / 取消缩进：四行（上下两行满宽、中间两行让出左边），左边一个小三角指向右或左（点睛）。"""
    def build(m):
        g = GROW[m]
        w = 2.6 + 1.2 * g
        lines = [bar([(-10.0, y), (10.0, y)], w) for y in (-8.4, 8.4)] + [bar([(-0.4, y), (10.0, y)], w) for y in (-2.8, 2.8)]
        tri = [(-10.6, -3.6), (-4.4, 0), (-10.6, 3.6)] if direction > 0 else [(-4.4, -3.6), (-10.6, 0), (-4.4, 3.6)]
        return [Layer("lines", lines), Layer("arrow", [grown(tri if direction > 0 else tri[::-1], [0.8] * 3, g * 0.8)], "secondary")]
    return build


def chain(linked):
    """链接 / 解除链接：两只 U 形的环（开口相对）斜着摆，连上时中间一截短杠把它们串起来（点睛）；解开时两环拉开、没有杠。"""
    def build(m):
        g = GROW[m]
        w, h, end = 2.8 + 1.2 * g, 4.4 + 1.4 * g, 2.4 + 0.4 * g
        apart = 0 if linked else 1.6
        a = bar([(-end - apart, -h), (-6.4 - apart, -h), (-6.4 - apart - h, 0), (-6.4 - apart, h), (-end - apart, h)], w, [0, h * 0.98, h * 0.98, h * 0.98, 0])
        b = bar([(end + apart, -h), (6.4 + apart, -h), (6.4 + apart + h, 0), (6.4 + apart, h), (end + apart, h)], w, [0, h * 0.98, h * 0.98, h * 0.98, 0])
        layers = [Layer("a", turned([a], -45)), Layer("b", turned([b], -45))]
        if linked:
            layers.append(Layer("bar", turned([bar([(-3.4, 0), (3.4, 0)], w)], -45), "secondary"))
        return layers
    return build


FOLDER_SEAM = -3.4


def folder_shape(g, c):
    """文件夹：后片（带左上的页签）与前片之间一道平刀口。"""
    back = grown([(-11, -9.0), (-3.0, -9.0), (-1.0, -6.4), (11, -6.4), (11, FOLDER_SEAM - c - 2 * g), (-11, FOLDER_SEAM - c - 2 * g)],
                 [1.6, 0.6, 0.6, 1.6, 0, 0], g)
    front = grown([(-11, FOLDER_SEAM), (11, FOLDER_SEAM), (11, 9.0), (-11, 9.0)], [0, 0, 2.2, 2.2], g)
    return back, front


def mark_plus(c, s, w):
    return [cross_shape_at(c, 4.4 * s, w * s / 2)]


def cross_shape_at(c, L, hw):
    pts = [(-hw, -L), (hw, -L), (hw, -hw), (L, -hw), (L, hw), (hw, hw), (hw, L), (-hw, L), (-hw, hw), (-L, hw), (-L, -hw), (-hw, -hw)]
    return rpoly([(c[0] + x, c[1] + y) for x, y in pts], [hw * 0.9, hw * 0.9, 0] * 4)


def mark_minus(c, s, w):
    return [bar([(c[0] - 4.0 * s, c[1]), (c[0] + 4.0 * s, c[1])], w * s)]


FOLDER_BADGE = (7.6, 6.0)


def folder(mark=None):
    """文件夹一族：文件夹（项目绑的目录）；右下让出一个圆位嵌一颗角标（点睛），角标里刻 +（新建项目）、−（解除绑定）、?（文件夹找不到了）。"""
    def build(m):
        g, c = GROW[m], CARVE[m]
        back, front = folder_shape(g, c)
        if not mark:
            return [Layer("folder", [back, front])]
        r = 4.9 + 0.4 * g
        front = clip(front, Outside(FOLDER_BADGE, r + c))
        badge = [disc(FOLDER_BADGE, r)] + holed(mark(FOLDER_BADGE, 0.62, MARK_W(m, 3.2)))
        return [Layer("folder", [back, front]), Layer("badge", badge, "secondary")]
    return build


def books(m):
    """资料：书架上三本书，前两本立着（一高一矮）、第三本斜靠，书与书之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    out = [grown([(x0, top), (x1, top), (x1, 10.4), (x0, 10.4)], [1.0] * 4, g)
           for x0, x1, top in ((-11.0, -5.6, -10.4), (-5.6 + c + 2 * g, -0.6, -7.6))]
    lean = [(x + 2.6, y + 0.6) for x, y in (rot(p, 16) for p in [(0, -10.6), (5.0, -10.6), (5.0, 9.6), (0, 9.6)])]
    out.append(grown(lean, [1.0] * 4, g))
    return [Layer("books", out)]


def pin_parts(g, c):
    """竖着的图钉：钉帽、钉身、钉尖三块，之间各一条横的刻缝。不斜放：斜放时刻缝正好与取消置顶的斜杠平行，斜杠读成又一道缝。"""
    k = 1.2
    head = grown(sc(k, [(-4.6, -11.0), (4.6, -11.0), (4.6, -8.2), (-4.6, -8.2)]), [1.4, 1.4, 0.6, 0.6], g)
    top = -8.2 * k + g + c + g
    body = grown([(-2.8 * k, top), (2.8 * k, top)] + sc(k, [(2.8, -2.2), (5.8, 1.2), (5.8, 3.0), (-5.8, 3.0), (-5.8, 1.2), (-2.8, -2.2)]),
                 [0, 0, 1.6, 0.8, 0.6, 0.6, 0.8, 1.6], g)
    nw = 1.6 + 0.6 * g
    needle = bar([(0, 3.0 * k + g + c + nw / 2), (0, 10.8 * k)], nw)
    return head, body, needle


def pin(m):
    """置顶：一枚图钉，钉尖是点睛。"""
    head, body, needle = pin_parts(GROW[m], CARVE[m])
    return [Layer("pin", [head, body]), Layer("needle", [needle], "secondary")]


UNPIN_K = -1.0  # 斜杠往右上平移多少格（切口避开三个母版结构不一的位置）


def unpin(m):
    """取消置顶：同"没有在同步""通知已关"，一道斜杠斜着贯穿图钉，钉身被劈开、切口一条刻缝；斜杠与横的刻缝成 45°，12pt 也看得出被划掉。"""
    head, body, needle = pin_parts(GROW[m], CARVE[m])
    w, bar_ = slash(m, 13.0, UNPIN_K)
    return [Layer("pin", [p for part in (head, body, needle) for p in slash_cut(part, m, w, UNPIN_K)]), Layer("slash", [bar_])]


def sheets(fold):
    """两张叠着的纸：前一张整张，后一张只露出左上的 L 形（被前一张挡住的地方让出一条刻缝）。
    fold：前一张右上折角（拷贝，纸的折角是点睛）；不折是两个版本（冲突）。"""
    def build(m):
        g, c = GROW[m], CARVE[m]
        bx0, by0, fx0, fy0, x1, y1 = -11.0, -11.0, -5.4, -5.4, 11.0, 11.0
        bx1, by1 = x1 - 5.6, y1 - 5.6
        back = grown([(bx0, by0), (bx1, by0), (bx1, fy0 - c - 2 * g), (fx0 - c - 2 * g, fy0 - c - 2 * g), (fx0 - c - 2 * g, by1), (bx0, by1)],
                     [2.4, 2.4, 0, 0, 0.8, 2.4], g)
        if not fold:
            return [Layer("sheets", [back, grown([(fx0, fy0), (x1, fy0), (x1, y1), (fx0, y1)], [2.4] * 4, g)])]
        e = 5.0 + g * 0.5
        front = grown([(fx0, fy0), (x1 - e - c, fy0), (x1 - e - c, fy0 + e + c), (x1, fy0 + e + c), (x1, y1), (fx0, y1)], [2.4, 0.4, 0, 0.4, 2.4, 2.4], g)
        ear = rpoly([(x1 - e + g, fy0 - g), (x1 + g, fy0 + e - g), (x1 - e + g, fy0 + e - g)], [0.6, 0.6, 0])
        return [Layer("sheets", [back, front]), Layer("ear", [ear], "secondary")]
    return build


def deck(m):
    """全部：错开的一叠卡片，前一张完整，后两张同样大、依次往右上错开，只露出上边与右边的 L 形，各隔一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    d, size = 3.6, 14.8
    out = []
    for k in range(3):
        x0, y1 = -11.0 + k * d, 11.0 - k * d
        x1, y0 = x0 + size, y1 - size
        if k == 0:
            out.append(grown([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], [2.4] * 4, g))
            continue
        ix, iy = x1 - d + c + 2 * g, y0 + d - c - 2 * g
        out.append(grown([(x0, y0), (x1, y0), (x1, y1), (ix, y1), (ix, iy), (x0, iy)], [1.4, 2.4, 1.4, 0.4, 0, 0.4], g))
    return [Layer("deck", out)]


TRAY_ARROW_S, TRAY_ARROW_G = 0.55, 0.5  # 托盘里的胖箭头缩多小、随字重外扩几成（两臂之间的口子窄，外扩多了碰臂）


def tray_arrow(up):
    """分享（箭头从托盘里往上出去）/ 存成灵感（箭头往下落进托盘）：一只 U 形托盘，上沿两臂之间留口，箭头穿过口子，各隔一条刻缝。"""
    def build(m):
        g = GROW[m]
        w = 2.8 + 1.2 * g
        tray = bar([(-5.0, -2.4), (-9.6, -2.4), (-9.6, 10.0), (9.6, 10.0), (9.6, -2.4), (5.0, -2.4)], w, [0, 2.6, 2.6, 2.6, 2.6, 0])
        a = fat_arrow(g * TRAY_ARROW_G, 0, TRAY_ARROW_S, (0, -6.0)) if up else fat_arrow(g * TRAY_ARROW_G, 180, TRAY_ARROW_S, (0, 1.2))
        return [Layer("tray", [tray]), Layer("arrow", [a])]
    return build


def pencil_parts(a, b, w, c):
    """一支铅笔（模板单位以外都按格）：a 是笔尖，b 是笔尾；笔尖一小块三角（点睛）、笔杆一块，之间一条刻缝。"""
    d = norm(sub(b, a)); n = left(d)
    tip_len = w * 1.25
    base = add(a, mul(d, tip_len))
    tip = rpoly([a, add(base, mul(n, w / 2)), sub(base, mul(n, w / 2))], [0.5, 0, 0])
    s = add(base, mul(d, c))
    body = rpoly([add(s, mul(n, w / 2)), add(b, mul(n, w / 2)), sub(b, mul(n, w / 2)), sub(s, mul(n, w / 2))], [0, 1.2, 1.2, 0])
    return tip, body


def pencil(m):
    """重命名、改文件：一支斜放的铅笔，笔尖朝左下，笔尖是点睛。"""
    g, c = GROW[m], CARVE[m]
    tip, body = pencil_parts((-9.6, 9.6), (9.2, -9.2), 5.0 + 1.2 * g, c)
    return [Layer("pencil", [body]), Layer("tip", [tip], "secondary")]


def write(m):
    """写：一张纸（圆角方框，右上让出一个口）上斜放一支铅笔，笔尖落在纸里，笔尖是点睛。"""
    g, c = GROW[m], CARVE[m]
    w = 2.6 + 1.2 * g
    box = bar([(-1.0, -9.6), (-9.6, -9.6), (-9.6, 9.6), (9.6, 9.6), (9.6, 1.0)], w, [0, 2.8, 2.8, 2.8, 0])
    tip, body = pencil_parts((-3.0, 3.0), (11.4, -11.4), 4.4 + 1.1 * g, c)
    return [Layer("paper", [box, body]), Layer("tip", [tip], "secondary")]


def choose(m):
    """挑选（下拉）：上下两块实心 V（同箭头的块），一朝上一朝下。"""
    g = GROW[m] * 0.8
    half, drop, t, dy = 5.6, 4.4, 2.8, 5.2
    top = -(drop + t) / 2
    up = [(0, top), (half, top + drop), (half, top + drop + t), (0, top + t), (-half, top + drop + t), (-half, top + drop)]
    radii = [0.6, 0.5, 0.5, 0, 0.5, 0.5]
    # 朝下的那块是朝上的上下翻过来：翻转后走向成了逆时针，点序倒过来
    down = [(x, -y + dy) for x, y in up][::-1]
    return [Layer("up", [grown([(x, y - dy) for x, y in up], radii, g)]), Layer("down", [grown(down, radii[::-1], g)])]


def filter_lines(m):
    """筛选：三道居中的横条，一道比一道短。"""
    g = GROW[m]
    w = 2.8 + 1.2 * g
    return [Layer("lines", [bar([(-h, y), (h, y)], w) for h, y in ((10.0, -7.0), (6.4, 0), (2.8, 7.0))])]


def puzzle(m):
    """扩展：一块拼图——方块的上边与右边各凸出一个圆头。"""
    g = GROW[m]
    body = grown([(-9.6, -6.4), (6.4, -6.4), (6.4, 9.6), (-9.6, 9.6)], [2.0] * 4, g)
    return [Layer("piece", [body, disc((-1.6, -8.4), 3.4 + g), disc((8.4, 1.6), 3.4 + g)])]
