"""状态图标（会话、同步、通知）：几个形状族各一份几何，换刻进去的记号或加一个角标出几个。"""
from __future__ import annotations

from .geometry import _side
from .icons_basic import *

# ---------- 状态（会话、同步、通知）：几个形状族各一份几何，换刻进去的记号或加一个角标出几个 ----------
# 记号（问号、叹号、勾、箭头……）是刻进体块的孔（`holed`）：状态图标整个按状态色画，记号是透出来的底，小字号也最清楚。
# 孔随字重收窄（`MARK_W`），体块随字重外扩：重量来自墨。孔是刻出来的，箭镞的角是利的。

def MARK_W(m, base=3.0): return base - 0.5 * GROW[m]


class Outside:
    """圆外一侧（裁切用）：到圆心的距离减 R（格）；切口是这个圆的一段，给角标让出一条刻缝。
    轮廓顺时针走，切口凹进体块，沿圆逆时针走（圆心在体块里时这一段超过半圈，不能取短的那段）。"""
    def __init__(self, c, R, n=8):
        self.c, self.R, self.n = mul(c, G), R * G, n

    def f(self, x): return dist(x, self.c) - self.R

    def edge(self, E, N):
        a0 = ang(sub(E, self.c)); sw = (ang(sub(N, self.c)) - a0) % (2 * math.pi) - 2 * math.pi
        return catmull([E] + [add(self.c, mul((math.cos(a0 + sw * k / self.n), math.sin(a0 + sw * k / self.n)), self.R)) for k in range(1, self.n)] + [N])


def arrow(segs, width, head):
    """一笔带箭镞（模板单位）：尾端圆头，头端是三角箭镞；head=(镞长, 镞半宽)。"""
    h, (hl, hw) = width / 2, head
    L, R = _side(segs, h), _side(segs, -h)
    P1, t, P0 = segs[-1].end(), segs[-1].dir1(), segs[0].start()
    n = left(t)
    a, tip, b = add(P1, mul(n, hw)), add(P1, mul(t, hl)), sub(P1, mul(n, hw))
    c = L + [Line(L[-1].end(), a), Line(a, tip), Line(tip, b), Line(b, R[-1].end())] + rev(R) + [Arc(P0, h, ang(left(segs[0].dir0())) + math.pi, math.pi)]
    return c if area(c) > 0 else rev(c)


def at(c, s, p): return (c[0] + p[0] * s, c[1] + p[1] * s)


def mark_question(c, s, w):
    hook = stroke([*arcs(at(c, s, (0, -3.0)), 3.4 * s, 195, 255), Line(mul(at(c, s, (0, 0.4)), G), mul(at(c, s, (0, 2.2)), G))], w * s * G)
    return [hook, disc(at(c, s, (0, 6.0)), 1.75 * s * w / 3.0)]


def mark_exclaim(c, s, w):
    return [bar([at(c, s, (0, -6.6)), at(c, s, (0, 1.8))], w * s), disc(at(c, s, (0, 6.0)), 1.8 * s * w / 3.0)]


def mark_tick(c, s, w):
    return [bar([at(c, s, (-5.6, 0.2)), at(c, s, (-1.8, 4.0)), at(c, s, (5.8, -4.4))], w * s)]


def mark_pause(c, s, w):
    return [bar([at(c, s, (x, -4.4)), at(c, s, (x, 4.4))], w * s) for x in (-2.7, 2.7)]


def mark_arrow(c, s, w, down=False):
    """胖箭头（`fat_arrow`）当记号：按记号的宽 w（基准 3 格）外扩或内收。"""
    return [fat_arrow((w - 3.0) / 2 * s, 180 if down else 0, 0.6 * s, c)]


def mark_uturn(c, s, w):
    """往回折的箭头（没能送达：话折回来了）：从左下往右、绕过右边折回上面，箭镞朝左。"""
    P = lambda p: mul(at(c, s, p), G)
    segs = [Line(P((-3.2, 5.0)), P((1.6, 5.0))), *[Arc(P((1.6, 1.0)), 4.0 * s * G, math.radians(90), math.radians(-180), 2)], Line(P((1.6, -3.0)), P((-2.6, -3.0)))]
    return [arrow(segs, w * s * G, (3.4 * s * G, 3.8 * s * G))]


def mark_cycle(c, s, w):
    """转一圈的箭头（同步中）：一段 270° 的弧，箭镞顺时针。"""
    return [arrow(arcs(c, 4.2 * s, 30, 250), w * s * G, (2.8 * s * G, 3.2 * s * G))]


def slash_cut(shape, m, w, k=0.0):
    """被一道左上到右下的斜杠劈开：两块各离斜杠一条刻缝，斜杠是自己一块（关掉、停掉、断了）。整块落在一侧的不切，原样留下。k 把斜杠往右上平移（格），
    躲开切口正好落在圆角与直边交界处的位置——那里三个母版会一个切在弧上、一个切在直边上，结构对不上。"""
    line = [mul((-16 + k, -16 - k), G), mul((16 + k, 16 - k), G)]
    off = (w / 2 + CARVE[m]) * G
    return [p for p in (clip(shape, Along(line, off, 1)), clip(shape, Along(line, -off, -1))) if p]


def slash(m, a=9.6, k=0.0):
    w = 2.6 + 1.2 * GROW[m]
    return w, bar([(-a * 0.7071 + k, -a * 0.7071 - k), (a * 0.7071 + k, a * 0.7071 - k)], w)


def badge(mark, solid=True):
    """圆标：实心圆里刻出记号（要你看的：等你、出错、没能送达，与选上），或一圈圆环、记号自己一块嵌在里面（不急的：未知）。
    实心圆同系统的 circle.fill 一样大（半径 12.6 格，比线条的圆大一圈）：放进同一行字里，与系统符号一般高。"""
    def build(m):
        g = GROW[m]
        if solid:
            return [Layer("badge", [disc((0, 0), BADGE_R + g)] + holed(mark((0, 0.3), 1.1, MARK_W(m))))]
        T = 2.6 + 1.2 * g
        return [Layer("ring", [disc((0, 0), 11.6 + T / 2), disc((0, 0), 11.6 - T / 2, hole=True)]),
                Layer("mark", mark((0, 0.3), 0.88, 3.0 + 1.2 * g))]
    return build


def question(m):
    """说明（技能与规则页的问号圆钮）：只一个问号、不带圆——它本身就嵌在一颗圆钮里。问号同"未知"里那个，放大到满格。"""
    return [Layer("question", mark_question((0, 0.3), 1.55, 3.0 + 1.2 * GROW[m]))]


BADGE_R = 12.6
# 没有圆底的状态图形按这个倍数放大：同一行字里，系统的同类符号都比圆标宽、高出一截（气泡、星、闪电、光标 K，铃 BK，云最宽 CK，
# 照系统 bell、icloud 在同一字号下的实测宽高定）
K, BK, CK = 1.15, 1.3, 1.5


def sc(k, points): return [(x * k, y * k) for x, y in points]


def picked(m):
    """选上：反白符号，同系统 checkmark.circle.fill 的分层——勾在第一层，刻了勾槽的实心圆是第二层的底。
    调用方给两种颜色（勾色、底色）时按层上色；只给一种时单色，勾嵌在槽里。App 里不按层级渲染（`Icon` 的 `.filled`）。"""
    g, c = GROW[m], CARVE[m]
    w = MARK_W(m, 2.6)
    return [Layer("tick", mark_tick((0, 0.3), 1.1, w)),
            Layer("badge", [disc((0, 0), BADGE_R + g)] + holed(mark_tick((0, 0.3), 1.1, w + 2 * c)), "secondary", ground=True)]


def bubble_question(m):
    """等 Cue 回答：对话气泡（尾巴在左下）是一圈墨，问号自己一块嵌在里面——同未知的圆环，不急、不是要你管的，不用实心。"""
    g = GROW[m]
    T, top, bottom = 2.2 + 1.1 * g, -10.8, 5.8
    box, radii = [(-11, top), (11, top), (11, bottom), (-11, bottom)], [4.2] * 4
    outer = grown(sc(K, [(-11, top), (11, top), (11, bottom), (-0.8, bottom), (-6.4, 11.0), (-5.8, bottom), (-11, bottom)]), [4.2, 4.2, 4.2, 0.6, 0.6, 0.4, 4.2], g)
    return [Layer("bubble", [outer, rev(grown(sc(K, box), radii, g - T))]), Layer("mark", mark_question((0, K * (top + bottom) / 2 + 0.2), 0.58 * K, 3.2 + 1.0 * g))]


def ring_slash(m):
    """已结束：一圈圆环被一道斜杠劈断（环在斜杠两边各断开一条刻缝）。"""
    g, c = GROW[m], CARVE[m]
    T, r = 2.6 + 1.2 * g, 11.0
    w, bar_ = slash(m, r + T / 2)
    d = math.degrees(math.asin((w / 2 + c + T / 2) / r))
    return [Layer("ring", [bow((0, 0), r, 45 + d, 180 - 2 * d, T), bow((0, 0), r, 225 + d, 180 - 2 * d, T)]), Layer("slash", [bar_])]


BOLT = [(-1.4, -11.6), (6.6, -11.6), (2.0, -2.8), (7.8, -2.8), (-5.0, 11.8), (-1.4, 0.8), (-7.6, 0.8)]


def broken_line(m):
    """被打断（做到一半停下，说一句就接着做）：一条横线在正中断开，两截上下错开一点——线断了，不是停了也不是结束了。
    不用闪电（Cue 页经过里"会话有动静"是整根闪电，缺口在小字号下不到 1pt，两个读成一个），不用圈（带圈的已经够多）。"""
    g, c = GROW[m], CARVE[m]
    w, gap, step = 3.4 + 1.4 * g, 2.6 + c - 2 * g, 1.7
    return [Layer("line", [bar([(-10.6, step), (-gap / 2 - w / 2, step)], w), bar([(gap / 2 + w / 2, -step), (10.6, -step)], w)])]


def relay(stalled=False):
    """等子代理交回：一颗大点（会话）在正中，一颗小点（子代理）在右上——同状态标里会动的那两颗（`RelayMark`：直径是框边的 0.44 与 0.26，小点心离正中 0.34），静止时就是它。
    `stalled`（子代理卡住了）：小点换成一个大一号的空心圈、大点往左下让——交出去的没动静了；13pt 里圈边约 1.4pt、孔约 2.6pt，小号里不读成实心。"""
    def build(m):
        g = GROW[m]
        big = disc((0, 0), 5.3 + g)
        if not stalled:
            return [Layer("home", [big]), Layer("away", [disc((8.2, -8.2), 3.1 + g)])]
        o = (7.2, -7.2)
        return [Layer("home", [disc((-2.2, 2.2), 4.7 + g)]), Layer("away", [disc(o, 5.2 + g * 0.6), disc(o, 2.6 - g * 0.4, hole=True)])]
    return build


GAP = 1.0


def cursor(m):
    """该你了：一行字（一条圆角的块），后面跟着输入光标（工字：上下两道横、中间一竖）——轮到你接着打字。"""
    g, c = GROW[m], CARVE[m]
    x, hw, sw, top, cap = 5.4 * K, 4.0 * K, 1.5 + 0.6 * g, 10.8 * K + 0.5 * g, 2.7 + g
    pts = [(x - hw, -top), (x + hw, -top), (x + hw, -top + cap), (x + sw, -top + cap), (x + sw, top - cap), (x + hw, top - cap), (x + hw, top),
           (x - hw, top), (x - hw, top - cap), (x - sw, top - cap), (x - sw, -top + cap), (x - hw, -top + cap)]
    beam = rpoly(pts, [1.1, 1.1, 0.9, 0.8, 0.8, 0.9, 1.1, 1.1, 0.9, 0.8, 0.8, 0.9])
    right = x - hw - c - 2 * g
    block = grown([(-11.0 * K, -3.4 * K), (right, -3.4 * K), (right, 3.4 * K), (-11.0 * K, 3.4 * K)], [1.8] * 4, g)
    return [Layer("text", [block]), Layer("cursor", [beam])]


def star(c, R, q, g):
    """四角星（格）：四个尖是小圆角，尖与尖之间的腰是往里凹的弧。"""
    pts = []
    for k in range(4):
        a = math.radians(k * 90 - 90)
        pts.append((c[0] + R * math.cos(a), c[1] + R * math.sin(a)))
        b = a + math.pi / 4
        pts.append((c[0] + q * math.cos(b), c[1] + q * math.sin(b)))
    return rpoly(pts, [0.7 + 0.4 * g, R * 0.36] * 4)


def sparkle(m):
    """新会话：一颗四角星。"""
    g = GROW[m]
    return [Layer("star", [star((0, 0), 11.4 * K + g, 3.5 * K + g, g)])]


def sparkles(m):
    """Agent：一大一小两颗四角星，小的（右上）是点睛。"""
    g = GROW[m]
    return [Layer("star", [star((-2.4 * K, 2.4 * K), 9.2 * K + g, 2.8 * K + g, g)]),
            Layer("spark", [star((6.8 * K, -6.8 * K), 4.7 * K + 0.6 * g, 1.3 * K + 0.4 * g, g)], "secondary")]


def circle_arrow(m, count=1):
    """重来：绕圈的粗箭头。一支（要重新载入，绕 290°）或两支首尾相追（立即同步、换新上下文）。"""
    g = GROW[m]
    w, r = 3.2 + 1.3 * g, 9.4
    head = (3.6 * G, 4.2 * G + g * G)
    if count == 1:
        return [Layer("arrow", [arrow(arcs((0, 0.6), r, -40, 280), w * G, head)])]
    return [Layer(f"arrow{k}", [arrow(arcs((0, 0), r, 200 + 180 * k, 125), w * G, head)]) for k in range(2)]


def cloud_shape(g):
    """云：左小、中大、右中三个圆的上沿接起来，底边是平的。三段弧的段数写死，三个母版才能插值。"""
    L, T, R, bottom = ((-6.5 * CK, 3.2 * CK), 4.4 * CK + g), ((-0.7 * CK, -1.2 * CK), 6.4 * CK + g), ((5.3 * CK, 2.0 * CK), 5.6 * CK + g), 7.6 * CK + g
    def meet(a, b):
        (c1, r1), (c2, r2) = a, b
        d = dist(c1, c2); x = (d * d + r1 * r1 - r2 * r2) / (2 * d); y = math.sqrt(r1 * r1 - x * x)
        u = norm(sub(c2, c1))
        return min((add(add(c1, mul(u, x)), mul(left(u), s * y)) for s in (1, -1)), key=lambda p: p[1])
    def arc(circle, p, q, pieces):
        c, r = circle
        a0, a1 = ang(sub(p, c)), ang(sub(q, c))
        sw = (a1 - a0) % (2 * math.pi)
        assert sw / pieces < math.radians(100), "云的一段弧太长"
        return Arc(mul(c, G), r * G, a0, sw, pieces)
    lt, tr = meet(L, T), meet(T, R)
    lb, rb = (L[0][0], bottom), (R[0][0], bottom)
    return [arc(L, lb, lt, 2), arc(T, lt, tr, 2), arc(R, tr, rb, 3), Line(mul(rb, G), mul(lb, G))]


CLOUD_MARK = (0.2 * CK, 2.2 * CK)


def cloud(mark=None, scale=0.5):
    """同步一族：同一朵云，刻进去的记号说同步的状态——空（正在连接）、勾（已同步）、转圈（同步中）、叹号（出了问题）、暂停、上箭头（上传本机）、下箭头（用云端替换）。"""
    def build(m):
        body = cloud_shape(GROW[m])
        return [Layer("cloud", [body] + (holed(mark(CLOUD_MARK, scale * CK, MARK_W(m))) if mark else []))]
    return build


def cloud_slash(m):
    """没有在同步：云被斜杠劈开。"""
    w, bar_ = slash(m, 11.0 * CK, -0.8)
    return [Layer("cloud", slash_cut(cloud_shape(GROW[m]), m, w, -0.8)), Layer("slash", [bar_])]


LOCK = (7.4, 3.4)  # 锁体左上角的位置（乘 CK 之前的格）


def cloud_lock(m):
    """账号受限：云的右下角让出一个圆位（锁的外接圆再加一条刻缝），嵌一把锁（点睛）。锁体是一整块方墨、锁梁粗，12pt 下还是锁的样子。"""
    g, c = GROW[m], CARVE[m]
    x, top = LOCK[0] * CK, LOCK[1] * CK
    bw, bottom, r, t = 4.8 + 0.4 * g, top + 6.2 + 0.3 * g, 3.0, 2.3 + 0.5 * g
    lock = rpoly([(x - bw, top), (x + bw, top), (x + bw, bottom), (x - bw, bottom)], [1.0] * 4)
    shackle = bow((x, top), r, 180, 180, t)
    o = (x, (top - r - t / 2 + bottom) / 2)
    R = max(dist(sample(sg, k / 16), mul(o, G)) for ct in (lock, shackle) for sg in ct for k in range(17)) / G
    return [Layer("cloud", [clip(cloud_shape(g), Outside(o, R + c))]), Layer("lock", [lock, shackle], "secondary")]


def bell_shape(g):
    return grown(sc(BK, [(-6.6, -11.0), (6.6, -11.0), (6.6, 0.4), (9.8, 4.2), (9.8, 6.0), (-9.8, 6.0), (-9.8, 4.2), (-6.6, 0.4)]),
                 [6.5 * BK, 6.5 * BK, 3.0, 1.0, 0.8, 0.8, 1.0, 3.0], g)


def clapper(m):
    g, c = GROW[m], CARVE[m]
    r = 1.9 * BK + 0.5 * g
    return disc((0, 6.0 * BK + g + c + r), r)


def bell(m):
    """通知一族：铃身一块，铃舌（下面一颗）隔一条刻缝，是点睛——它回你了、开着通知。"""
    return [Layer("bell", [bell_shape(GROW[m])]), Layer("clapper", [clapper(m)], "secondary")]


def bell_on(m):
    """通知已开：铃的右上角让出一个圆位，嵌一颗角标（点睛）。"""
    g, c = GROW[m], CARVE[m]
    o, r = (8.0 * BK, -9.0 * BK), 2.8 * BK + 0.4 * g
    return [Layer("bell", [clip(bell_shape(g), Outside(o, r + c)), clapper(m)]), Layer("badge", [disc(o, r)], "secondary")]


def bell_off(m):
    """通知已关：铃被斜杠劈开。"""
    w, bar_ = slash(m, 11.0 * BK, -0.9)
    return [Layer("bell", slash_cut(bell_shape(GROW[m]), m, w, -0.9) + [clapper(m)]), Layer("slash", [bar_])]
