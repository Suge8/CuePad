#!/usr/bin/env python3
"""从品牌 logo（design/final/logo-final.png：黑色 C + 小纸片）生成 Icon Composer 图标 App/Sources/AppIcon.icon。
位图先 3 倍放大、阈值成黑白，再用 potrace 描成矢量，按"C"和"纸片"拆成两个图层（Liquid Glass 需要分层）。
浅色：白底黑图形；深色：深灰底白图形；着色：白图形（底色由系统着色）。
依赖：Pillow、potrace（brew install --build-from-source potrace）。用法：make-icon.py
"""
import json, os, re, shutil, subprocess, tempfile
from PIL import Image, ImageChops

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
LOGO = os.path.join(ROOT, "design/final/logo-final.png")
OUT = os.path.join(ROOT, "apple/App/Sources/AppIcon.icon")
CANVAS = 1024
GLYPH_WIDTH = 620  # 构图（C + 纸片）在画布上的宽度
UPSCALE = 3
PAPER_BOX = (812, 474, 1016, 760)  # 纸片在原图里的矩形；C 的两个端点都在这个矩形之外

def trace(image, work, name):
    bmp, svg = os.path.join(work, name + ".bmp"), os.path.join(work, name + ".svg")
    black_and_white = image.point(lambda v: 0 if v < 128 else 255, "1")
    black_and_white.save(bmp)
    subprocess.run(["potrace", "-s", "--turdsize", "40", "--alphamax", "1.1", "--opttolerance", "0.5", "-o", svg, bmp], check=True)
    path = re.search(r'<path d="([^"]+)"', open(svg).read(), re.S).group(1)
    return " ".join(path.split()), ImageChops.invert(black_and_white.convert("L")).getbbox()

def main():
    logo = Image.open(LOGO).convert("L")
    big = logo.resize((logo.width * UPSCALE, logo.height * UPSCALE), Image.LANCZOS)
    box = tuple(v * UPSCALE for v in PAPER_BOX)
    paper_only = Image.new("L", big.size, 255)
    paper_only.paste(big.crop(box), box[:2])
    c_only = big.copy()
    c_only.paste(255, box)
    with tempfile.TemporaryDirectory() as work:
        c_path, c_box = trace(c_only, work, "c")
        paper_path, paper_box = trace(paper_only, work, "paper")
    x0, y0 = min(c_box[0], paper_box[0]), min(c_box[1], paper_box[1])
    x1, y1 = max(c_box[2], paper_box[2]), max(c_box[3], paper_box[3])
    scale = GLYPH_WIDTH / ((x1 - x0) / UPSCALE)
    unit = scale / (UPSCALE * 10)  # potrace 坐标单位是位图像素的 1/10
    tx = CANVAS / 2 - (x0 + x1) / 2 / UPSCALE * scale
    ty = (big.height / UPSCALE - (y0 + y1) / 2 / UPSCALE) * scale + CANVAS / 2

    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(os.path.join(OUT, "Assets"))
    for name, path in (("c", c_path), ("paper", paper_path)):
        with open(os.path.join(OUT, "Assets", name + ".svg"), "w") as f:
            f.write(f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" viewBox="0 0 {CANVAS} {CANVAS}">\n'
                    f'<path fill="#000000" fill-rule="evenodd" transform="matrix({unit:.6f} 0 0 {-unit:.6f} {tx:.3f} {ty:.3f})" d="{path}"/>\n</svg>\n')

    def solid(r, g, b): return {"solid": f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"}
    def layer(name):
        return {"glass": True, "image-name": name + ".svg", "name": name, "position": {"scale": 1, "translation-in-points": [0, 0]},
                "fill-specializations": [{"value": solid(0, 0, 0)}, {"appearance": "dark", "value": solid(1, 1, 1)},
                                         {"appearance": "tinted", "value": solid(1, 1, 1)}]}
    icon = {
        "fill-specializations": [{"value": solid(1, 1, 1)}, {"appearance": "dark", "value": solid(0.09, 0.09, 0.10)}],
        "groups": [{"layers": [layer("paper"), layer("c")], "shadow": {"kind": "neutral", "opacity": 0.5},
                    "translucency": {"enabled": False, "value": 0.5}}],
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(OUT, "icon.json"), "w") as f:
        json.dump(icon, f, indent=2, ensure_ascii=False)
    print(OUT)

if __name__ == "__main__":
    main()
