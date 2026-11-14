"""CuePad 图标唯一生成入口：python3 design/tools/cue-symbols.py（仅标准库）。

功能图标由 ink/rounded 的等宽中线、圆头与相切圆角生成三字重 SF Symbol；
提醒问号裸放，失败保留语义实心徽。Cue 品牌几何在 ink/mascot.py，保持原样。
同时生成 App / Widget 资源、Debug 名录与 Swift 状态中线；不在运行时解析 SVG。
验证入口：python3 design/tools/verify-symbols.py。
"""
from __future__ import annotations

import shutil
from pathlib import Path
from tempfile import TemporaryDirectory

from ink.geometry import *
from ink.mascot import mascot
from ink.rounded import BUILDERS, draw
from ink.state_geometry import swift_geometry

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "apple/App/Sources/Assets.xcassets/Symbols"
NAMES_SWIFT = ROOT / "apple/App/Sources/UI/Debug/InkSymbols.swift"
WIDGET_OUT = ROOT / "apple/App/Widget/Symbols.xcassets"
ICON_MONO = ROOT / "apple/App/Sources/AppIcon.icon/Assets/cue-mono.svg"
STATE_SWIFT = ROOT / "apple/App/Sources/UI/Shared/Theme/InkStateGeometry.swift"
LANDING_MARK = ROOT / "landing/static/assets/mark.svg"
ICON_GRID_PX = 36  # 剪影在 1024 画布上一格多少像素：全身约 810 × 780，四周留足图标蒙版的边
WIDGET_SYMBOLS = ("waiting", "mail", "done", "agent")  # 小组件与实时活动用到的（`WidgetIcon`）
PREFIX = "cue"


SYMBOLS = {"mascot": mascot} | {name: lambda weight, name=name: draw(name, weight) for name in BUILDERS}


# ---------- 写出 ----------
def fmt(v): return f"{v:.3f}".rstrip("0").rstrip(".")


def d_of(contour, dx, dy, *, stable=False):
    def coordinate(v):
        # hypot 的跨版本 ULP 差异不能改变 SVG 的千分位舍入；品牌路径保留原始编码。
        return fmt(round(v, 9) if stable else v)
    def P(p): return f"{coordinate(p[0] + dx)},{coordinate(p[1] + dy)}"
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


def template(per, *, stable):
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
                 f'd="{" ".join(d_of(c, dx, -MID, stable=stable) for c in L.contours)}"/>' for i, L in enumerate(per[w])]
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


def symbol_files():
    files = {OUT / "Contents.json": INFO, WIDGET_OUT / "Contents.json": INFO}
    for name, build in SYMBOLS.items():
        per = {w: build(w) for w in WEIGHTS}
        for w in WEIGHTS: check_gaps(name, per[w], w)
        check_accent(name, per["Regular"])
        full = f"{PREFIX}.{name}"
        folder = OUT / f"{full}.symbolset"
        svg = template(per, stable=name != "mascot")
        info = (
            '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n'
            '  "properties" : {\n    "symbol-rendering-intent" : "template"\n  },\n  "symbols" : [\n    {\n'
            f'      "filename" : "{full}.svg",\n      "idiom" : "universal"\n    }}\n  ]\n}}\n')
        files[folder / f"{full}.svg"] = svg
        files[folder / "Contents.json"] = info
        if name in WIDGET_SYMBOLS:
            widget = WIDGET_OUT / folder.name
            files[widget / f"{full}.svg"] = svg
            files[widget / "Contents.json"] = info
    return files


def silhouette_files():
    """Cue 的纯白剪影（全部层涂白，缝与眼孔保留）：App 图标着色、透明外观用的（居中在 1024 画布上），落地页品牌小标（`.brandmark` 的蒙版）用的（紧贴外框）。"""
    layers = mascot("Regular")
    pts = [sample(sg, k / 32) for L in layers for c in L.contours for sg in c for k in range(33)]
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    y0, y1 = min(p[1] for p in pts), max(p[1] for p in pts)
    d = " ".join(d_of(c, 0, 0) for L in layers for c in L.contours)
    k = ICON_GRID_PX / G
    mono = (
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
        f'<path fill="#FFFFFF" transform="translate({512 - (x0 + x1) / 2 * k:.2f} {512 - (y0 + y1) / 2 * k:.2f}) scale({k:.5f})" d="{d}"/>\n</svg>\n')
    mark = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{fmt(x0)} {fmt(y0)} {fmt(x1 - x0)} {fmt(y1 - y0)}">\n'
        f'<path fill="#FFFFFF" d="{d}"/>\n</svg>\n')
    return {ICON_MONO: mono, LANDING_MARK: mark}


def symbol_names():
    names = "\n".join(f'        "{PREFIX}.{name}",' for name in SYMBOLS)
    return (
        "#if DEBUG\n"
        "// 由 design/tools/cue-symbols.py 生成。\n\n"
        "/// 全部自定义符号的资源名，按生成器里的顺序：只给图标总览（`IconSheet`）列全；产品代码按意思经 `Icon` 取图。\n"
        "enum InkSymbols {\n"
        f"    static let names = [\n{names}\n    ]\n"
        "}\n"
        "#endif\n")



def generate():
    """在触碰资源前完成全部几何、模板与跨语言输出；失败保留原来的整套文件。"""
    return symbol_files() | silhouette_files() | {NAMES_SWIFT: symbol_names(), STATE_SWIFT: swift_geometry()}


def write(files):
    """每个文件原子替换；全部写完后才清掉本生成器不再拥有的符号目录。"""
    for path, content in files.items():
        if path.exists() and path.read_text(encoding="utf-8") == content:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        with TemporaryDirectory(dir=path.parent) as staging:
            temporary = Path(staging) / path.name
            temporary.write_text(content, encoding="utf-8")
            temporary.replace(path)
    for directory in (OUT, WIDGET_OUT):
        for folder in directory.glob(f"{PREFIX}.*.symbolset"):
            if folder / "Contents.json" not in files:
                shutil.rmtree(folder)


if __name__ == "__main__":
    write(generate())
