"""CuePad 自家的图标（墨块）：从几何直接生成自定义 SF Symbol（模板 7.0，Ultralight / Regular / Black 三个母版插值），
整个重写 App 资源目录的 Symbols 下（两端共用，资源名 cue.<名>），小组件与实时活动要的几个另拷一份进小组件自己的资源目录（`WIDGET_SYMBOLS`，扩展里没有 App 的资源），并生成 LoopLayer 取用的"话在路上"三块 V 的路径（`ClimbBlocks.swift`）
与图标总览（`IconSheet`）列的全部符号名（`InkSymbols.swift`，只在 Debug 构建里）。
用法：python3 design/tools/cue-symbols.py（只用标准库）。这里只有符号表与写出；几何在 `ink/geometry.py`，各族图标在 `ink/icons_*.py`。

墨块的规则（每个图标都守）：
- 主体是实心的体块，细节是刻进去的缝与孔，不描边。外形圆、刀口直：剪影的拐角与自由端是圆的，刻进体块的缝是直的、利的。
- 体块之间、点睛与它的槽之间都隔一条刻缝（`CARVE`），层与层不重叠：单色下（系统菜单、工具栏里所有层同色）缝还在，认得出。生成时逐个检查，窄了就报错。
- 最多一块点睛，放在第二层（hierarchical 的 secondary，调色板渲染的第二个颜色）。点睛平时什么颜色、什么时候点亮是 App 代码里的着色规则，符号只管分层。
  点睛只能是小部件（一处点、一条缝里的块，不超过整个图形墨量的 `ACCENT_SHARE`，按 Regular 量、生成时检查——细的母版里主体墨少，占比自然高）：主体在主层——点睛平时是次一级的颜色，
  主体放进点睛层的话，没选中时整个图标是灰的，像被禁用。没有合适的小部件就不设点睛。
- 字重：体块按母版外扩 / 内缩（`GROW`），孔跟着缩 / 扩，缝在粗的母版里收窄一点——重量来自墨，不来自线。
- 品牌的物件：纸（圆角方纸 + 右上折角）、C 环（logo 的粗 C）、Cue（纸身体 + 斜着的腰环 + 竖着的眼）。

坐标：24 格，原点在图形中心、y 向下；1 格 = G 个模板单位，半径 12 格的圆 = 系统的 circle。图形中心落在大写字母高度的中线上，所以与文字基线对齐、随字号缩放。
同一个符号的三个母版轮廓命令序列必须逐条一致才能插值（写出前断言）：几何按字重变的只能是位置，不能是拐角、分段的有无。
"""
from __future__ import annotations

import shutil
from pathlib import Path

from ink.icons_project import *

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "apple/App/Sources/Assets.xcassets/Symbols"
CLIMB_SWIFT = ROOT / "apple/App/Sources/UI/Shared/Theme/ClimbBlocks.swift"
NAMES_SWIFT = ROOT / "apple/App/Sources/UI/Debug/InkSymbols.swift"
WIDGET_OUT = ROOT / "apple/App/Widget/Symbols.xcassets"
WIDGET_SYMBOLS = ("waiting", "done")  # 小组件与实时活动用到的（`WidgetIcon`）
PREFIX = "cue"


SYMBOLS = {
    "mascot": mascot("open"),
    "mascot.sleep": mascot("sleep"),
    "mascot.look": mascot("look"),
    "mascot.happy": mascot("happy"),
    "idea": idea,
    "task": task,
    "session": session,
    "search": search(),
    "settings": settings,
    "archive": archive,
    "trash": trash,
    "sidebar": sidebar,
    "plus": plus,
    "close": close,
    "clear": clear,
    "more": more,
    "chevron.up": chevron(0),
    "chevron.right": chevron(90),
    "chevron.down": chevron(180),
    "chevron.left": chevron(270),
    "stop": stop,
    "done": done(),
    "done.pre": done("pre"),
    "climb": climb,
    "waiting": badge(mark_question),
    "failure": badge(mark_exclaim),
    "undelivered": badge(mark_uturn),
    "unknown": badge(mark_question, solid=False),
    "picked": picked,
    "asking": bubble_question,
    "ended": ring_slash,
    "interrupted": bolt_cut,
    "cursor": cursor,
    "sparkle": sparkle,
    "agent": sparkles,
    "reload": lambda m: circle_arrow(m, 1),
    "renew": lambda m: circle_arrow(m, 2),
    "cloud": cloud(),
    "cloud.done": cloud(mark_tick),
    "cloud.sync": cloud(mark_cycle, 0.6),
    "cloud.alert": cloud(mark_exclaim),
    "cloud.pause": cloud(mark_pause, 0.56),
    "cloud.up": cloud(mark_arrow),
    "cloud.down": cloud(lambda c, s, w: mark_arrow(c, s, w, down=True)),
    "cloud.off": cloud_slash,
    "cloud.lock": cloud_lock,
    "bell": bell,
    "bell.on": bell_on,
    "bell.off": bell_off,
    "reopen": ring_mark(mark_uturn),
    "restore": restore,
    "play": play,
    "indent": indent(1),
    "outdent": indent(-1),
    "link": chain(True),
    "unlink": chain(False),
    "folder": folder(),
    "folder.add": folder(mark_plus),
    "folder.remove": folder(mark_minus),
    "books": books,
    "pin": pin,
    "unpin": unpin,
    "copy": sheets(True),
    "conflict": sheets(False),
    "deck": deck,
    "grid": grid,
    "share": tray_arrow(True),
    "save": tray_arrow(False),
    "pencil": pencil,
    "write": write,
    "choose": choose,
    "filter": filter_lines,
    "puzzle": puzzle,
    "tick": tick,
    "plane": plane,
    "plane.done": plane_done,
    "bolt": bolt,
    "clock": ring_mark(mark_hands),
    "arrow.up": pointing(0),
    "arrow.down": pointing(180),
    "ring.down": ring_mark(lambda c, s, w: mark_arrow(c, s, w, down=True)),
    "ring.stop": ring_mark(mark_square),
    "ring.play": ring_mark(mark_play),
    "ring.plus": ring_mark(mark_plus),
    "badge.down": badge_dart,
    "compact": compact,
    "enlarge": enlarge,
    "hand": hand,
    "mac": mac,
    "photo": photo,
    "photos": photos,
    "camera": camera,
    "select": select_text,
    "keyboard.down": keyboard_down,
    "braces": braces,
    "terminal": terminal,
    "window": window,
    "doc": paper(paper_lines),
    "doc.blank": paper(),
    "wrench": wrench,
    "bubble.text": bubble("text"),
    "bubble.dots": bubble("dots"),
    "branch": branch,
    "dot": dot,
    "flame": flame,
    "hammer": hammer,
    "layers": layers3,
    "brush": brush,
    "eye": eye,
    "person": person,
    "bookmark": bookmark,
    "power": power,
    "bubble": bubble_solid,
    "alarm": alarm,
    "swap": swap,
    "mail": mail,
    "tag": tag,
    "shield.tick": shield_tick,
    "keyboard": keyboard,
    "sun": sun,
    "wave": wave,
    "cube": cube,
    "bubbles": bubbles,
    "globe": globe,
    "target": target,
    "briefcase": briefcase,
    "cart": cart,
    "megaphone": megaphone,
    "flag": flag,
    "leaf": leaf,
    "house": house,
    "heart": heart,
    "star": star5,
    "music": music,
    "rocket": rocket,
    "menubar": menubar,
}


# ---------- 写出 ----------
def fmt(v): return f"{v:.3f}".rstrip("0").rstrip(".")


def d_of(contour, dx, dy):
    def P(p): return f"{fmt(p[0] + dx)},{fmt(p[1] + dy)}"
    out = [f"M{P(contour[0].start())}"]
    for s in contour:
        if isinstance(s, Line):
            out.append(f"L{P(s.b)}")
        elif isinstance(s, Cubic):
            out.append(f"C{P(s.p1)} {P(s.p2)} {P(s.p3)}")
        else:
            n = s.pieces or max(1, math.ceil(abs(s.sweep) / (math.pi / 2) - 1e-9))
            step = s.sweep / n
            k = 4 / 3 * math.tan(step / 4)
            for i in range(n):
                a, b = s.a0 + step * i, s.a0 + step * (i + 1)
                p0, p3 = s.pt(a), s.pt(b)
                c1 = add(p0, mul((-math.sin(a), math.cos(a)), k * s.r))
                c2 = sub(p3, mul((-math.sin(b), math.cos(b)), k * s.r))
                out.append(f"C{P(c1)} {P(c2)} {P(p3)}")
    out.append("Z")
    return " ".join(out)


def structure(layers):
    return ["".join(ch for ch in d_of(c, 0, 0) if ch in "MLCZ") for L in layers for c in L.contours]


def check_gaps(name, layers, m):
    """层与层之间最窄的缝不能比刻缝窄：单色下靠它分开。"""
    pts = [[sample(s, k / 24) for c in L.contours for s in c for k in range(24)] for L in layers]
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            d = min(dist(a, b) for a in pts[i] for b in pts[j]) / G
            assert d >= CARVE[m] * 0.9, f"{name} {m}：{layers[i].name} 与 {layers[j].name} 之间的缝只有 {d:.2f} 格（刻缝 {CARVE[m]}）"


def check_accent(name, layers):
    """点睛只能是小部件：主体放进点睛层，平时次一级的颜色下整个图标是灰的。"""
    ink = [abs(sum(area(c) for c in L.contours)) for L in layers]
    accent = sum(a for a, L in zip(ink, layers) if L.tier == "secondary" and not L.ground)
    assert accent <= ACCENT_SHARE * sum(ink), f"{name}：点睛占了墨量的 {accent / sum(ink):.0%}（最多 {ACCENT_SHARE:.0%}），主体要在主层"


def template(per):
    """per：{母版: [Layer]}。"""
    s = {w: structure(per[w]) for w in WEIGHTS}
    assert len({str(v) for v in s.values()}) == 1, f"三个母版结构不一致：{ {w: len(v) for w, v in s.items()} }"
    line = 'style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
    guides = [f'<line id="Baseline-{s}" {line} x1="263" x2="3036" y1="{b}" y2="{b}"/>'
              f'<line id="Capline-{s}" {line} x1="263" x2="3036" y1="{b - 70.459:.3f}" y2="{b - 70.459:.3f}"/>'
              for s, b in (("S", 696), ("M", 1126), ("L", 1556))]
    groups = []
    tiers = [L.tier for L in per["Regular"]]
    for w in ("Black", "Regular", "Ultralight"):
        xs = [sample(sg, k / 32)[0] for L in per[w] for c in L.contours for sg in c for k in range(33)]
        width = max(xs) - min(xs) + 2 * BEARING
        left_ = COLUMNS[w] - width / 2
        dx = -min(xs) + BEARING
        guides.append(f'<line id="left-margin-{w}-S" {line} x1="{left_:.3f}" x2="{left_:.3f}" y1="600.785" y2="720.121"/>'
                      f'<line id="right-margin-{w}-S" {line} x1="{left_ + width:.3f}" x2="{left_ + width:.3f}" y1="600.785" y2="720.121"/>')
        paths = [f'<path class="monochrome-{i} multicolor-{i}:tintColor hierarchical-{i}:{tiers[i]} SFSymbolsPreviewWireframe" '
                 f'd="{" ".join(d_of(c, dx, -MID) for c in L.contours)}"/>' for i, L in enumerate(per[w])]
        groups.append(f'<g id="{w}-S" transform="matrix(1 0 0 1 {left_:.3f} {BASELINE})">{"".join(paths)}</g>')
    styles = [".defaults {-sfsymbols-variable-value-mode:color;-sfsymbols-draw-reverses-motion-groups:false}"]
    for i in range(len(tiers)):
        for prefix in (f"monochrome-{i}", f"multicolor-{i}:tintColor", f"hierarchical-{i}:{tiers[i]}"):
            styles.append(f".{prefix} {{-sfsymbols-motion-group:{i}}}")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3300 2200">\n'
            f'<style>{chr(10).join(styles)}\n.SFSymbolsPreviewWireframe {{fill:none;opacity:1.0;stroke:black;stroke-width:0.5}}</style>\n'
            '<g id="Notes"><rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>'
            '<text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" '
            'transform="matrix(1 0 0 1 3036 1933)">Template v.7.0</text></g>\n'
            f'<g id="Guides">{"".join(guides)}</g>\n'
            f'<g id="Symbols">{"".join(groups)}</g>\n</svg>\n')


INFO = '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n'


def write_symbols():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    (OUT / "Contents.json").write_text(INFO)
    for name, build in SYMBOLS.items():
        per = {w: build(w) for w in WEIGHTS}
        for w in WEIGHTS: check_gaps(name, per[w], w)
        check_accent(name, per["Regular"])
        full = f"{PREFIX}.{name}"
        folder = OUT / f"{full}.symbolset"
        folder.mkdir()
        (folder / f"{full}.svg").write_text(template(per))
        (folder / "Contents.json").write_text(
            '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n'
            '  "properties" : {\n    "symbol-rendering-intent" : "template"\n  },\n  "symbols" : [\n    {\n'
            f'      "filename" : "{full}.svg",\n      "idiom" : "universal"\n    }}\n  ]\n}}\n')


def write_widget_symbols():
    shutil.rmtree(WIDGET_OUT, ignore_errors=True)
    WIDGET_OUT.mkdir(parents=True)
    (WIDGET_OUT / "Contents.json").write_text(INFO)
    for name in WIDGET_SYMBOLS:
        shutil.copytree(OUT / f"{PREFIX}.{name}.symbolset", WIDGET_OUT / f"{PREFIX}.{name}.symbolset")


def write_climb():
    blocks = ",\n".join("        [" + ", ".join(f"CGPoint(x: {fmt(x)}, y: {fmt(y)})" for x, y in climb_block(tip)) + "]" for tip in CLIMB_TIPS)
    CLIMB_SWIFT.write_text(
        "// 由 design/tools/cue-symbols.py 生成，改形状改那里（符号 cue.climb 出自同一份）。\n"
        "import CoreGraphics\n\n"
        '/// "话在路上"三块实心 V 的顶点：22 × 22、y 朝下的格子，从下往上排（`LoopLayer.climb` 画它）。\n'
        "enum ClimbBlocks {\n"
        f"    static let blocks: [[CGPoint]] = [\n{blocks},\n    ]\n"
        "}\n")


def write_names():
    names = "\n".join(f'        "{PREFIX}.{name}",' for name in SYMBOLS)
    NAMES_SWIFT.write_text(
        "#if DEBUG\n"
        "// 由 design/tools/cue-symbols.py 生成。\n\n"
        "/// 全部墨块符号的资源名，按生成器里的顺序：只给图标总览（`IconSheet`）列全；产品代码按意思经 `Icon` 取图。\n"
        "enum InkSymbols {\n"
        f"    static let names = [\n{names}\n    ]\n"
        "}\n"
        "#endif\n")


if __name__ == "__main__":
    write_symbols()
    write_widget_symbols()
    write_climb()
    write_names()
