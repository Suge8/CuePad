"""Cue 与设置、文件预览的类型。"""
from __future__ import annotations

from .icons_objects import *

# ---------- Cue 与设置、文件预览的类型 ----------

def badge_arrow(m):
    """自动检查更新：实心圆里刻一支朝下的胖箭头（同一份几何，缩小，居中）。"""
    return [Layer("badge", [disc((0, 0), BADGE_R + GROW[m]), rev(fat_arrow(0.0, 180, 0.62, (0, 0.4)))])]


def bookmark(m):
    """Cue 记得什么：一枚书签——上沿圆角的长条，下端剪出一个 V 口。"""
    g = GROW[m]
    return [Layer("bookmark", [grown([(-7.4, -11.0), (7.4, -11.0), (7.4, 11.0), (0, 5.4), (-7.4, 11.0)], [2.4, 2.4, 0.6, 0.4, 0.6], g)])]


def power(m):
    """刚启用：电源——一圈开口朝上的粗环，开口里竖一根短杠，杠与环之间一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    T, r = 3.0 + 1.2 * g, 9.0
    w = T
    d = math.degrees(math.asin((w / 2 + c + T / 2) / r)) + 4
    ring = bow((0, 1.6), r, -90 + d, 360 - 2 * d, T)
    stem = bar([(0, -11.2), (0, -1.6)], w)
    return [Layer("power", [ring, stem])]


def bubble_solid(m):
    """你发来消息、对 Cue 说：一只实心的对话气泡（同说了一句的那只，不挖空）。"""
    ring, _ = bubble_outline(GROW[m], 0)
    return [Layer("bubble", [ring[0]])]


def alarm(m):
    """提醒到点：闹钟——圆环钟面与指针（同排队的钟），头上左右各一只小铃（点睛），离钟面一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    T = 2.6 + 1.2 * g
    o, R = (0, 1.4), 9.4
    face = [disc(o, R + T / 2), disc(o, R - T / 2, hole=True)]
    hands = mark_hands(o, 0.72, (3.0 + 1.2 * g) / 0.72 * 0.88)
    rb = 2.5 + 0.3 * g
    bells = [disc(add(o, rot((0, -(R + T / 2 + c + rb)), k * 42)), rb) for k in (-1, 1)]
    return [Layer("clock", face + hands), Layer("bells", bells, "secondary")]


def mail(m):
    """邮件：一只信封——一块圆角实心，刻出信封盖的 V 槽。"""
    g = GROW[m]
    body = grown([(-11.0, -8.4), (11.0, -8.4), (11.0, 8.4), (-11.0, 8.4)], [2.4] * 4, g)
    flap = bar([(-7.6, -4.6), (0, 1.4), (7.6, -4.6)], MARK_W(m, 2.6), [0, 2.0, 0])
    return [Layer("mail", [body] + holed([flap]))]


def tag(m):
    """名字：一枚吊牌——右边削尖的圆角牌子，左头挖一个穿绳的孔。"""
    g = GROW[m]
    body = grown([(-11.0, -7.2), (3.6, -7.2), (11.0, 0), (3.6, 7.2), (-11.0, 7.2)], [2.2, 1.2, 1.4, 1.2, 2.2], g)
    return [Layer("tag", [body, disc((-6.4, 0), 2.0 - 0.3 * g, hole=True)])]


def keyboard(m):
    """快捷键：一块键盘，刻出两排键与一条空格（同收起键盘那块，不带 V）。"""
    g = GROW[m]
    board = grown([(-11.0, -7.4), (11.0, -7.4), (11.0, 7.4), (-11.0, 7.4)], [2.4] * 4, g)
    k = 1.25 - 0.2 * g
    keys = [disc((x, y), k) for y in (-3.4, 0.4) for x in (-6.6, -2.2, 2.2, 6.6)]
    space = bar([(-4.4, 4.0), (4.4, 4.0)], 2 * k)
    return [Layer("board", [board] + holed(keys + [space]))]


def sun(m):
    """外观：一轮太阳——实心圆盘，外面一圈八道短光芒，各隔一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    r = 5.0 + g
    w = 2.6 + 1.0 * g
    r0 = r + c + w / 2
    rays = [bar([rot((0, -r0), k * 45), rot((0, -11.2 + w / 2), k * 45)], w) for k in range(8)]
    return [Layer("sun", [disc((0, 0), r)] + rays)]


def wave(m):
    """音频：一排高矮不一的圆头竖条（声波）。"""
    g = GROW[m]
    w = 2.6 + 1.1 * g
    xs, hs = (-9.0, -4.5, 0, 4.5, 9.0), (3.4, 7.6, 11.0, 6.0, 2.6)
    return [Layer("wave", [bar([(x, -h + w / 2), (x, h - w / 2)], w) for x, h in zip(xs, hs)])]


def cube(m):
    """转动查看：一只等轴的立方体，顶面、左面、右面三块，之间各一条刻缝。"""
    g, c = GROW[m], CARVE[m]
    a, h = 10.4, 6.0  # 半宽、顶面半高
    top = grown([(0, -11.6), (a, -11.6 + h), (0, -11.6 + 2 * h), (-a, -11.6 + h)], [0.8, 0.8, 0.2, 0.8], g)
    d = (c + 2 * g) / math.cos(math.atan(h / a))
    mid = (0, -11.6 + 2 * h + d)
    k = c / 2 + g  # 左右两面各外扩 g 后，中间那道竖缝正好一条刻缝
    dy = k * h / a
    left_ = grown([(-a, -11.6 + h + d), (-k, mid[1] - dy), (-k, 11.6 - dy), (-a, 11.6 - h)], [0.2, 0.2, 0.8, 0.8], g)
    right_ = grown([(k, mid[1] - dy), (a, -11.6 + h + d), (a, 11.6 - h), (k, 11.6 - dy)], [0.2, 0.2, 0.8, 0.8], g)
    return [Layer("cube", [top, left_, right_])]


def skill(m):
    """技能（技能与规则）：一张立着的手艺卡——圆角的牌，中间刻出一颗四角星的槽，星嵌在槽里（点睛）。
    与书（读书项目：书架上的几本书）、纸（文档：右上折角）都不撞形：牌没有折角、不分本。"""
    g, c = GROW[m], CARVE[m]
    card = grown([(-9.0, -11.2), (9.0, -11.2), (9.0, 11.2), (-9.0, 11.2)], [3.0] * 4, g)
    o = (0, 0.4)
    R, q = 5.8 - 0.3 * g, 2.0 - 0.1 * g
    slot = star(o, R + c * 1.8, q + c * 1.4, 0)
    gem = star(o, R, q, 0)
    return [Layer("card", [card] + holed([slot])), Layer("gem", [gem], "secondary")]
