"""项目图标与"话在路上"的三块 V。"""
from __future__ import annotations

from .icons_settings import *

# ---- 项目图标（项目表单里能挑的那张闭合表，见 App 的 `ProjectIcon`）：其余几种借现成的（文件夹、闪光、终端、锤子、书、画笔、灯泡、方块、层、相机）----
def bubbles(m):
    """对话：两只气泡，后面一只在左上（被前面那只挡掉一角，挡处让一条刻缝），前面一只在右下、尾巴朝右下。"""
    g, c = GROW[m], CARVE[m]
    cut = c + 2 * g  # 两块各外扩 g 后之间正好一条刻缝
    fx0, fy0 = -3.0, -2.6  # 前面那只的左上角
    back = grown([(-11.0, -10.4), (5.0, -10.4), (5.0, fy0 - cut), (fx0 - cut, fy0 - cut), (fx0 - cut, 2.6), (-6.0, 2.6), (-9.0, 5.6), (-8.6, 2.6), (-11.0, 2.6)],
                 [3.2, 3.2, 1.0, 1.2, 1.0, 0.4, 0.4, 0.4, 3.2], g)
    front = grown([(fx0, fy0), (11.0, fy0), (11.0, 7.4), (8.8, 7.4), (9.4, 10.8), (5.6, 7.4), (fx0, 7.4)], [3.2, 3.2, 3.2, 0.4, 0.4, 0.4, 3.2], g)
    return [Layer("bubbles", [back, front])]


def globe(m):
    """地球：实心圆被一条赤道、两条弯的经线刻开成六块（左右两牙、中间一枚分上下）。"""
    g, c = GROW[m], CARVE[m]
    R, A, h = 10.8 + g, 4.6, c / 2
    def mer(y): return A * math.sqrt(max(0.0, 1 - (y / R) ** 2))
    def ends(outer):  # 两牙在哪一高度与圆合上（刻缝宽 = 圆与经线的水平距），中间一枚在哪一高度收成尖
        return -R * math.sqrt(1 - (h / (R - A)) ** 2) if outer else -R * math.sqrt(1 - (h / A) ** 2)
    n = 8
    def P(x, y): return (x * G, y * G)
    def crescent(sx, sy):
        y1 = ends(True)
        ys = [-h + (y1 + h) * i / n for i in range(n + 1)]
        outer = [P(sx * math.sqrt(R * R - y * y), sy * y) for y in ys]
        inner = [P(sx * (mer(y) + h), sy * y) for y in reversed(ys)]
        segs = catmull(outer) + catmull(inner) + [Line(inner[-1], outer[0])]
        return segs if area(segs) > 0 else rev(segs)
    def lens(sy):
        y1 = ends(False)
        ys = [-h + (y1 + h) * i / n for i in range(n + 1)]
        right = [P(mer(y) - h, sy * y) for y in ys]
        left_ = [P(-(mer(y) - h), sy * y) for y in reversed(ys)]
        segs = catmull(right) + catmull(left_) + [Line(left_[-1], right[0])]
        return segs if area(segs) > 0 else rev(segs)
    return [Layer("globe", [crescent(sx, sy) for sx in (-1, 1) for sy in (1, -1)] + [lens(sy) for sy in (1, -1)])]


def target(m):
    """靶心：一圈粗环，正中一颗靶心（点睛），之间留一圈空。"""
    g = GROW[m]
    R, T = 11.0 + g * 0.5, 3.0 + 1.3 * g
    return [Layer("ring", [disc((0, 0), R), disc((0, 0), R - T, hole=True)]), Layer("bull", [disc((0, 0), 3.6 + 0.7 * g)], "secondary")]


def briefcase(m):
    """公文包：上面一道提手，包身被一条横的刻缝分成盖与身两块。"""
    g, c = GROW[m], CARVE[m]
    cut = c + 2 * g
    y0, ys, y1 = -4.6, 0.2, 10.0
    lid = grown([(-11.0, y0), (11.0, y0), (11.0, ys), (-11.0, ys)], [2.4, 2.4, 0.4, 0.4], g)
    body = grown([(-11.0, ys + cut), (11.0, ys + cut), (11.0, y1), (-11.0, y1)], [0.4, 0.4, 2.4, 2.4], g)
    w = 2.2 + 0.8 * g
    foot = y0 - g - c - w / 2
    handle = bar([(-4.6, foot), (-4.6, -11.0 + w / 2), (4.6, -11.0 + w / 2), (4.6, foot)], w, 1.6)
    return [Layer("case", [lid, body, handle])]


def cart(m):
    """购物车：左上一段把手连着往右撑开的筐，筐下两只轮子，离筐一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    w = 2.4 + 1.0 * g
    basket = grown([(-7.4, -6.4), (11.0, -6.4), (8.6, 3.0), (-5.2, 3.0)], [0.6, 1.2, 1.2, 0.6], g)
    handle = bar([(-11.0, -10.0), (-8.4, -10.0), (-6.4, -4.0)], w, 2.2)
    r = 2.2 + 0.5 * g
    y = 3.0 + g + c + r
    return [Layer("cart", [basket, handle, disc((-3.6, y), r), disc((7.0, y), r)])]


def megaphone(m):
    """喇叭：往右张开的喇叭筒，左边一截握把，之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    cut = c + 2 * g
    x = -4.4
    horn = grown([(x, -3.8), (10.6, -10.4), (10.6, 10.4), (x, 3.8)], [0.6, 1.6, 1.6, 0.6], g)
    grip = grown([(-11.0, -3.8), (x - cut, -3.8), (x - cut, 3.8), (-11.0, 3.8)], [1.4, 0.4, 0.4, 1.4], g)
    return [Layer("megaphone", [horn, grip])]


def flag(m):
    """旗帜：一根旗杆，右边一面燕尾旗，离杆一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    w = 2.6 + 1.1 * g
    x = -8.2
    pole = bar([(x, -10.6), (x, 11.0 - w / 2)], w)
    x0 = x + w / 2 + c + g
    cloth = grown([(x0, -10.6), (10.8, -10.6), (6.2, -4.2), (10.8, 2.2), (x0, 2.2)], [0.4, 0.6, 0.6, 0.6, 0.4], g)
    return [Layer("flag", [pole, cloth])]


def leaf(m):
    """叶子：两道弧合成的叶片斜放，刻出一道叶脉，左下伸出一截叶柄。"""
    g = GROW[m]
    a, b = (-5.6, 5.6), (10.6, -10.6)
    L = dist(a, b)
    bulge = 7.4 + g  # 叶片最宽处的半宽
    r = (L * L / 4 + bulge * bulge) / (2 * bulge)
    mid, u = mul(add(a, b), 0.5), norm(sub(b, a))
    n_ = left(u)
    a_, b_ = sub(a, mul(u, g)), add(b, mul(u, g))
    def side(sgn):
        c_ = add(mid, mul(n_, -sgn * (r - bulge)))
        a0, a1 = ang(sub(a_, c_)), ang(sub(b_, c_))
        sw = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        return Arc(mul(c_, G), r * G, a0, sw, 2)
    s1, s2 = side(1), side(-1)
    blade = [s1, reverse(s2)]
    blade = blade if area(blade) > 0 else rev(blade)
    w = MARK_W(m, 2.2)
    vein = bar([add(a, mul(u, 4.0)), add(b, mul(u, -4.4))], w)
    stem = bar([add(a, mul(u, 2.0)), add(a, mul(u, -4.6))], 2.4 + 1.0 * g)
    return [Layer("leaf", [blade] + holed([vein]) + [stem])]


def house(m):
    """家：一座实心的小屋（尖顶、方身），屋底正中开一扇门（门的宽高不随字重变）。"""
    g = GROW[m]
    d, top = 2.3 + g, 3.4 + g
    body = grown([(0, -11.0), (11.0, -1.4), (8.4, -1.4), (8.4, 10.6), (d, 10.6), (d, top), (-d, top), (-d, 10.6), (-8.4, 10.6), (-8.4, -1.4), (-11.0, -1.4)],
                 [1.4, 0.8, 0, 1.6, 0.4, 1.0, 1.0, 0.4, 1.6, 0, 0.8], g)
    return [Layer("house", [body])]


def heart(m):
    """心：一颗实心的心，顶上一道凹、底下一个尖。"""
    g = GROW[m]
    k = (11.4 + g) / 16
    def P(t): return (16 * math.sin(t) ** 3 * k, -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)) * k + 1.4)
    n = 10
    right = [mul(P(math.pi * i / n), G) for i in range(n + 1)]
    left_ = [(-x, y) for x, y in reversed(right)]
    segs = catmull(right) + catmull(left_)
    return [Layer("heart", [segs if area(segs) > 0 else rev(segs)])]


def star5(m):
    """星：一颗五角星，尖是小圆角（同闪光的四角星一家，角数不同不撞形）。"""
    g = GROW[m]
    R, q = 11.6 + g, 5.2 + g * 0.9
    pts = []
    for k in range(5):
        a = math.radians(k * 72 - 90)
        pts.append((R * math.cos(a), R * math.sin(a) + 0.8))
        b = a + math.radians(36)
        pts.append((q * math.cos(b), q * math.sin(b) + 0.8))
    return [Layer("star", [rpoly(pts, [0.9 + 0.4 * g, 0.4] * 5)])]


def music(m):
    """音符：两个符头连着两根符干，顶上一道斜的符梁。"""
    g = GROW[m]
    w = 2.4 + 1.0 * g
    r = 3.4 + 0.6 * g
    heads = [(-6.2, 7.0), (6.6, 4.6)]
    stems = [bar([(x + r - w / 2, y), (x + r - w / 2, top)], w) for (x, y), top in zip(heads, (-6.6, -9.0))]
    x0, x1 = heads[0][0] + r - w, heads[1][0] + r
    beam = grown([(x0, -6.6 - 1.2), (x1, -9.0 - 1.2 - 0.6), (x1, -9.0 + 2.6), (x0, -6.6 + 3.2)], [0.4, 0.4, 0, 0], g)
    return [Layer("music", [disc(h, r) for h in heads] + stems + [beam])]


def rocket(m):
    """火箭：机身斜指右上，尖头圆肩，开一扇圆舷窗；尾部两侧各一片贴着机身的尾翼、尾后一簇火焰，都离机身一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    cut = c + 2 * g
    hw, top, bottom = 4.6, -13.2, 4.4
    def place(p): return add(rot(p, 45), (-1.2, 1.2))
    body = grown([place(p) for p in [(0, top), (hw, top + 7.6), (hw, bottom), (-hw, bottom), (-hw, top + 7.6)]], [1.2, 4.6, 1.2, 1.2, 4.6], g)
    x0 = hw + cut
    fins = [grown([place((k * x, y)) for x, y in [(x0, -2.0), (9.4, 3.8), (9.4, 9.2), (x0, 6.8)][::k]], [0.4, 1.0, 0.8, 0.4], g) for k in (1, -1)]
    y0 = bottom + cut
    flame = grown([place(p) for p in [(-3.0, y0), (3.0, y0), (0, y0 + 6.0)]], [0.6, 0.6, 1.2], g)
    window = disc(place((0, -4.0)), 2.2 - 0.5 * g, hole=True)
    return [Layer("rocket", [body, window] + fins + [flame])]


def menubar(m):
    """菜单栏里的 CuePad（同 logo）：一圈往右开口的粗 C，开口里嵌一张折角的小纸。只在菜单栏用，单色模板图。"""
    g, c = GROW[m], CARVE[m]
    T = 4.2 + 1.4 * g
    ring = bow((-3.2, 0), 8.0 - T / 2, 45, 270, T)
    x0, y0, x1, y1 = 5.2, -3.6, 11.2, 4.6
    e = 2.8
    paper_ = grown([(x0, y0), (x1 - e, y0), (x1, y0 + e), (x1, y1), (x0, y1)], [1.0, 0.2, 0.2, 1.0, 1.0], g)
    return [Layer("mark", [ring, paper_])]


# "话在路上"三块实心 V：外沿 V 的尖在 tip、两端降 DROP（斜率同燕尾箭的箭镞），竖厚 THICK，两端竖切；从下往上排。
# 22 格、y 朝下（LoopLayer 的画布），符号里减去中心 11。LoopLayer 的 climb 与符号 cue.climb 都只从这里来。
CLIMB_TIPS, CLIMB_HALF, CLIMB_DROP, CLIMB_THICK = (12.1, 6.9, 1.7), 6.8, 5.1, 3.2


def climb_block(tip):
    return [(11, tip), (11 + CLIMB_HALF, tip + CLIMB_DROP), (11 + CLIMB_HALF, tip + CLIMB_DROP + CLIMB_THICK),
            (11, tip + CLIMB_THICK), (11 - CLIMB_HALF, tip + CLIMB_DROP + CLIMB_THICK), (11 - CLIMB_HALF, tip + CLIMB_DROP)]


def climb(m):
    """话在路上（静止版，减弱动态效果与菜单里）：三块实心 V，与状态标里循环的 LoopLayer.climb 同形。字重只外扩四成 g，块间刀口不被吃掉。"""
    g = GROW[m] * 0.4
    return [Layer("climb", [grown([(x - 11, y - 11) for x, y in climb_block(tip)], [0] * 6, g) for tip in CLIMB_TIPS])]
