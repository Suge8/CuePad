"""Cue 品牌几何保持原样，与功能图标的等宽轮廓分开。"""
from .geometry import *

def mascot(m):
    """Cue（App 图标、菜单栏、图标族共用的唯一一份几何）：纸身体（右上让出折角的槽）、两只竖胶囊的眼挖出来、腰上一道斜带（照 3D 小人的环：约 15° 往右上斜，前半圈微微下垂压在身体上，刻缝隔开，两端略出身体，带下是身体的下摆），折角是点睛。
    16pt 单色下一眼读出纸、折角、眼、腰上那一道；不画环绕到身后的后半圈——它会让身体读成一顶帽子。"""
    g, c = GROW[m], CARVE[m]
    x0, x1, y0, y1, r, e = -9.2 - g, 9.2 + g, -10.4 - g, 11.2 + g, 4.4 + g, 3.7 + g * 0.5
    body = rpoly([(x0, y0), (x1 - e - c, y0), (x1 - e - c, y0 + e + c), (x1, y0 + e + c), (x1, y1), (x0, y1)],
                 [r, 0.5 + g * 0.5, 0, 0.5 + g * 0.5, r, r])
    t, reach, slope, sag, mid = 2.8 + 1.0 * g, 9.3, -0.26, 0.9, 4.2
    def Y(x): return mid + slope * x + sag * (1 - (x / reach) ** 2)
    def belt(span, n): return [mul((x, Y(x)), G) for x in [-span + 2 * span * k / n for k in range(n + 1)]]
    cut = belt(reach + 5, 60)
    upper = clip(body, Along(cut, t * G / 2 + c * G, 1))
    lower = clip(body, Along(cut, -(t * G / 2 + c * G), -1))
    band = thick(belt(reach, 40), t * G, 8)
    ex, ey = 3.0, -2.0
    erx, ery = 1.6 - g * 0.15, 2.4 - g * 0.15
    def eye(x): return bar([(x + 0.03, ey - ery + erx), (x, ey), (x + 0.03, ey + ery - erx)], 2 * erx)
    face = holed([eye(-ex), eye(ex)])
    ear = rpoly([(x1 - e, y0), (x1, y0 + e), (x1 - e, y0 + e)], [0.7 + g * 0.4, 0.7 + g * 0.4, 0])
    return [Layer("body", [upper] + face + [lower]), Layer("band", [band]), Layer("ear", [ear], "secondary")]
