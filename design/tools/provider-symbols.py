# /// script
# requires-python = ">=3.12"
# dependencies = ["picosvg==0.23.0"]
# ///
"""模型提供方的图标：把 LobeHub 单色图标（npm @lobehub/icons-static-svg，MIT，许可见仓库根目录 THIRD-PARTY-NOTICES.md）
转成自定义 SF Symbol，写进 App 的资源目录（两端共用）。用法：uv run design/tools/provider-symbols.py

图标按 LobeHub 的 24 格放成边长 SIDE 的方块、竖向居中在大写字母高度的中线上（与系统的圆形符号同高），所以与文字基线对齐、随字号缩放。
三种粗细放同一份路径：标志没有粗细之分。evenodd 由 picosvg 转成 nonzero（符号只认 nonzero）。
哪个提供方用哪个图标在 PiProvider（App 代码）里，这里只管有哪些图标。
"""
import re
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

from picosvg.svg import SVG
from picosvg.svg_transform import Affine2D

VERSION = "1.95.1"
OUT = Path(__file__).resolve().parents[2] / "apple/App/Sources/Assets.xcassets/Providers"
# 资源名（provider-<名>）→ LobeHub 图标名与取哪一块（24 格里的 x, y, 宽, 高；默认整格）
ICONS = {
    "anthropic": ("anthropic", None),
    "openai": ("openai", None),
    "gemini": ("gemini", None),
    "xai": ("xai", None),
    "deepseek": ("deepseek", None),
    "kimi": ("kimi", None),
    "openrouter": ("openrouter", None),
    # 整个图标是两行字标，小字号读不出；只取下面那一行 MiMo 标
    "mimo": ("xiaomimimo", (0, 13.4, 24, 6.4)),
    # 接入的 Agent（AgentKind 用哪个在 App 代码的 AgentMark 里）
    "claudecode": ("claudecode", None),
    "codex": ("codex", None),
    "opencode": ("opencode", None),
    "pi": ("pi", None),
}

# 模板的参考线（SF Symbols 模板 3.0，小号）：基线与大写字母高度
BASELINE, CAP_HEIGHT = 696.0, 70.459
SIDE = 84.0  # 24 格放成的边长，约是大写字母高度的 1.2 倍
PAD = 5.0  # 两侧留白（符号嵌在文字里时与前后字的间距）
COLUMNS = {"Ultralight-S": 559.0, "Regular-S": 1391.0, "Black-S": 2224.0}


def glyph(svg_path: Path, crop) -> tuple[str, float]:
    """符号坐标里的路径（原点在左边距、基线上）与宽度。"""
    x, y, w, h = crop or (0, 0, 24, 24)
    scale = SIDE / max(w, h) if crop is None else min(SIDE / w * 2.2, SIDE * 0.62 / h)
    width = w * scale
    middle = -CAP_HEIGHT / 2
    move = Affine2D(scale, 0, 0, scale, PAD - x * scale, middle - (y + h / 2) * scale)
    source = SVG.parse(str(svg_path))
    # 只留取的那一块：viewBox 收到这一块，picosvg 把块外的裁掉
    source.svg_root.set("viewBox", f"{x} {y} {w} {h}")
    picture = source.topicosvg().clip_to_viewbox()
    d = " ".join(shape.apply_transform(move).d for shape in picture.shapes())
    d = re.sub(r"-?\d+\.\d+", lambda m: f"{float(m.group()):.3f}".rstrip("0").rstrip("."), d)
    return d, width + 2 * PAD


def template(d: str, width: float) -> str:
    line = 'style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
    guides = [f'<line id="Baseline-{s}" {line} x1="263" x2="3036" y1="{b}" y2="{b}"/>'
              f'<line id="Capline-{s}" {line} x1="263" x2="3036" y1="{b - CAP_HEIGHT:.3f}" y2="{b - CAP_HEIGHT:.3f}"/>'
              for s, b in (("S", 696), ("M", 1126), ("L", 1556))]
    symbols = []
    for variant, center in COLUMNS.items():
        left = center - width / 2
        guides.append(f'<line id="left-margin-{variant}" {line} x1="{left:.3f}" x2="{left:.3f}" y1="600.785" y2="720.121"/>'
                      f'<line id="right-margin-{variant}" {line} x1="{left + width:.3f}" x2="{left + width:.3f}" y1="600.785" y2="720.121"/>')
        symbols.append(f'<g id="{variant}" transform="matrix(1 0 0 1 {left:.3f} {BASELINE})"><path d="{d}"/></g>')
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg version="1.1" xmlns="http://www.w3.org/2000/svg" width="3300" height="2200">\n'
        '<g id="Notes"><rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>'
        '<text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" '
        'transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text></g>\n'
        f'<g id="Guides">{"".join(guides)}</g>\n'
        f'<g id="Symbols">{"".join(symbols)}</g>\n</svg>\n'
    )


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["npm", "pack", f"@lobehub/icons-static-svg@{VERSION}", "--silent"], cwd=tmp, check=True, stdout=sys.stderr)
        with tarfile.open(next(Path(tmp).glob("*.tgz"))) as archive:
            archive.extractall(tmp, filter="data")
        icons = Path(tmp) / "package/icons"
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "Contents.json").write_text('{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
        for name, (source, crop) in ICONS.items():
            folder = OUT / f"provider-{name}.symbolset"
            folder.mkdir(exist_ok=True)
            (folder / f"provider-{name}.svg").write_text(template(*glyph(icons / f"{source}.svg", crop)))
            (folder / "Contents.json").write_text(
                '{\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "symbols" : [\n    {\n'
                f'      "filename" : "provider-{name}.svg",\n      "idiom" : "universal"\n    }}\n  ]\n}}\n')


main()
