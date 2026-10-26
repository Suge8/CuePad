"""Cue 头像的帧：从 design/cue-frames 里的底图（src，360px 宽、贴着外框裁好的五张表情，帧源只有这一套）与生成图（gen，gpt-image 以对应底图为参考
编辑出来的，提示词见 PROMPTS）对齐、修补、检查，再导出成 200px 见方（名片最大 64pt@3x 只用到约 190px）：
没有 3D 源（仓库全部历史、本机都查过，没有 blend、usdz、glb、fbx、riv 之类；5 张底图是当初抠好的位图，1254px 的原图在提交 a315ee23d 的 design/final/cue-*.png），帧只能这样生成再修补，每加一帧都要过下面的检查。
要加的新姿势超过 3 个、或要连续的动作（走、转身）时改走 Rive：那时一帧一帧地生成，风格漂移比重画一套骨骼更贵。
- 静止的那几张（`CueBeat.still`）写进 App Group 的 apple/App/AppGroup/CueFaces.xcassets：小组件、灵动岛与 App 共用；
- 只在帧序列里出现的写进 App 的 apple/App/Sources/Assets.xcassets/CueFrames（扩展里没有）。
两个目录都由这里整个重写。用法：uv run --with pillow --with numpy design/tools/cue-frames.py

怎么修补：生成图整只直接用会偏 1～3px、奶油色偏白一档，换帧时身体会跳。所以每帧都只从它的底图出：
- eyes：只动眼睛的帧（眨眼、张望、往上想）。按透明度与灰度把生成图对齐到底图，只把脸框里与底图差得多的那块羽化贴回，身体与透明度一像素不动。
- pose：换姿势的帧（凉棚、为难、换手欢呼）。按黑环对齐（手臂与星光会把外框带偏），奶油色按通道拉回底图那一档，
  只贴框里变了的地方。
两种都不换底图的黑环。
- half：半闭眼，不生成：每只眼睛的上半截换成同一族闭眼帧那一处（肤色与眼皮那道线），眨眼时插在睁、闭之间。
导出时每张都垫成方画布、脚底贴着下沿（底图高矮不一，只按宽缩放、竖着居中的话，换拍子时脚底会上下挪）。
检查（不过就报错、不写出；像素按导出后的算）：每帧与底图同画布；黑环外框与底图差不超过 `TOLERANCE` px；eyes 与 half 的整只外框也不超过；
pose 对齐后生成图的黑环与底图的一样宽、下沿一样高（差不超过 `TOLERANCE`）。
"""
from __future__ import annotations

import json
import shutil
from collections import deque
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "design/cue-frames"
STILLS = ROOT / "apple/App/AppGroup/CueFaces.xcassets"
MOVING = ROOT / "apple/App/Sources/Assets.xcassets/CueFrames"
WIDTH = 200
# 外框最多差几个导出后的像素
TOLERANCE = 2

STYLE = ("Edit the first reference image. Keep the exact same 3D clay mascot: a cream-white rounded paper-sheet body with a black folded top-right corner, "
         "a thick glossy black rubber ring around its waist, small stubby cream clay arms and legs, matte clay texture, soft studio light from the upper left, "
         "same colors, same camera angle, same framing and same character size as the reference, square canvas, character centered with feet at the bottom. "
         "Change only this:")
BLINK = ("the eyes are closed in a relaxed blink — each eye becomes a short, gently curved horizontal black clay line at exactly the same place as the open eyes. "
         "Everything else stays identical.")
# 生成图的提示词（STYLE 接这一句；参考图是括号里的底图，--transparent）：重生成时照用，换了提示词就要重新挑
PROMPTS = {
    "listening-blink": ("listening", BLINK),
    "listening-left": ("listening", "the two black oval eyes are moved toward the viewer's left side of the face, glancing left. Pose, raised hand, ring and body stay identical."),
    "visor": ("listening + waiting", "pose changed to waiting for someone far away: one stubby hand raised flat against the top of the forehead like a sun visor shading the eyes, "
              "the other arm relaxed at the side, the two black oval eyes shifted toward the viewer's right, peering into the distance. Same body, ring, legs and proportions."),
    "visor-left": ("visor", "the two black oval eyes are moved toward the viewer's left, now peering into the distance to the left under the visor hand."),
    "visor-blink": ("visor", BLINK),
    "thinking-up": ("thinking", "the eyes look up toward the upper right as if pondering, hand still on the chin. Pose, ring and body stay identical."),
    "thinking-blink": ("thinking", BLINK),
    "waiting-blink": ("waiting", BLINK),
    "done-blink": ("done", "Change only the happy curved eyes to short, nearly horizontal black eyelid lines for a gentle blink; retain the raised arms and sparkle."),
    "done-2": ("done", "the arms switch: the left arm is now down at the side and the right arm raised high in a cheer, the little golden four-point sparkle moves "
               "to the upper right of the head, happy closed-eye smile unchanged."),
    "failed": ("listening", "it is awake but stuck and troubled: the two eyes become small worried black clay dots with short slanted black clay eyebrows tilted down "
               "toward the outside, and the raised hand on the left rests on top of its head in a 'oops' gesture. Ring, body, legs and the other arm stay identical."),
}


@dataclass
class Frame:
    name: str
    base: str
    kind: str  # copy / eyes / pose / half
    box: tuple[int, int, int, int] | None = None  # 底图坐标里允许变的那块（eyes、pose）
    still: bool = False


# 脸框（底图坐标）：只在这里面找眼睛的变化
FACE = {"listening": (50, 90, 320, 250), "thinking": (50, 70, 320, 220), "waiting": (90, 100, 345, 240), "visor": (60, 100, 320, 230)}
FRAMES = [
    Frame("listening", "listening", "copy", still=True),
    Frame("thinking", "thinking", "copy", still=True),
    Frame("waiting", "waiting", "copy", still=True),
    Frame("done", "done", "copy", still=True),
    Frame("sleeping", "sleeping", "copy", still=True),
    Frame("visor", "listening", "pose", (0, 0, 262, 240), still=True),
    Frame("failed", "listening", "pose", (0, 0, 290, 250), still=True),
    Frame("listening-blink", "listening", "eyes", FACE["listening"]),
    Frame("listening-half", "listening", "half", FACE["listening"]),
    Frame("listening-left", "listening", "eyes", FACE["listening"]),
    Frame("visor-left", "visor", "eyes", FACE["visor"]),
    Frame("visor-blink", "visor", "eyes", FACE["visor"]),
    Frame("visor-half", "visor", "half", FACE["visor"]),
    Frame("thinking-up", "thinking", "eyes", FACE["thinking"]),
    Frame("thinking-blink", "thinking", "eyes", FACE["thinking"]),
    Frame("thinking-half", "thinking", "half", FACE["thinking"]),
    Frame("waiting-blink", "waiting", "eyes", FACE["waiting"]),
    Frame("waiting-half", "waiting", "half", FACE["waiting"]),
    Frame("done-blink", "done", "eyes", (80, 110, 240, 160)),
    Frame("done-half", "done", "half", (80, 110, 240, 160)),
    Frame("done-2", "done", "pose", (0, 0, 360, 315)),
]


def arr(img): return np.asarray(img, np.float32)


def place(gen, scale, x, y, size):
    w, h = max(1, round(gen.width * scale)), max(1, round(gen.height * scale))
    canvas = Image.new("RGBA", size, (0, 0, 0, 0))
    canvas.paste(gen.resize((w, h), Image.LANCZOS), (round(x), round(y)))
    return canvas


def features(img, by):
    a = arr(img) / 255
    alpha = a[..., 3]
    gray = a[..., :3].mean(axis=2)
    if by == "ring":
        # 黑环（与折角、眼睛）：暗且不透明。手臂、星光不进成本，外框就不会被它们带偏
        return [((gray < 0.3) & (alpha > 0.8)).astype(np.float32)]
    return [alpha, gray * alpha]


def cost(base_f, cand, by):
    return float(sum(np.abs(f - b).mean() for f, b in zip(features(cand, by), base_f)))


def align(base, gen, by):
    """把生成图（裁到外框）缩放、平移到最贴底图：先半分辨率粗搜，再全分辨率细搜。"""
    gen = gen.crop(gen.getbbox())
    bb = base.getbbox()
    s0 = (bb[3] - bb[1]) / gen.height
    half = (base.width // 2, base.height // 2)
    base_f = features(base.resize(half, Image.LANCZOS), by)
    best = None
    for s in s0 * np.arange(0.88, 1.121, 0.01):
        cx, cy = (bb[0] + bb[2]) / 2 - gen.width * s / 2, bb[3] - gen.height * s
        for ox in range(-24, 25, 3):
            for oy in range(-24, 25, 3):
                c = cost(base_f, place(gen, s / 2, (cx + ox) / 2, (cy + oy) / 2, half), by)
                if best is None or c < best[0]:
                    best = (c, s, cx + ox, cy + oy)
    base_f = features(base, by)
    _, s1, x1, y1 = best
    best = None
    for s in s1 * np.arange(0.985, 1.0151, 0.0025):
        for ox in range(-3, 4):
            for oy in range(-3, 4):
                c = cost(base_f, place(gen, s, x1 + ox, y1 + oy, base.size), by)
                if best is None or c < best[0]:
                    best = (c, s, x1 + ox, y1 + oy)
    return place(gen, best[1], best[2], best[3], base.size)


def tone(img, ref):
    """奶油色拉回底图那一档：只看亮的不透明像素（纸面），按通道等比缩放。"""
    a, r = arr(img), arr(ref)
    def cream(x): return x[(x[..., 3] > 200) & (x[..., :3].mean(axis=2) > 170)][:, :3].mean(axis=0)
    a[..., :3] = np.clip(a[..., :3] * (cream(r) / cream(a)), 0, 255)
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def components(mask):
    """四连通的块，大的在前：每块是 (面积, (x0, y0, x1, y1), 像素列表)。"""
    seen = np.zeros(mask.shape, bool)
    out = []
    for y, x in zip(*np.nonzero(mask)):
        if seen[y, x]:
            continue
        seen[y, x] = True
        queue, pixels = deque([(y, x)]), []
        while queue:
            cy, cx = queue.popleft()
            pixels.append((cy, cx))
            for ny, nx in ((cy + 1, cx), (cy - 1, cx), (cy, cx + 1), (cy, cx - 1)):
                if 0 <= ny < mask.shape[0] and 0 <= nx < mask.shape[1] and mask[ny, nx] and not seen[ny, nx]:
                    seen[ny, nx] = True
                    queue.append((ny, nx))
        ys, xs = zip(*pixels)
        out.append((len(pixels), (min(xs), min(ys), max(xs) + 1, max(ys) + 1), pixels))
    return sorted(out, key=lambda c: -c[0])


def dark(img): a = arr(img); return (a[..., :3].mean(axis=2) < 70) & (a[..., 3] > 200)


def ring_box(img):
    """黑环的外框：最大的那块暗色（眼睛、折角都比它小）。"""
    return components(dark(img))[0][1]


def mask_of(base, aligned, box):
    """框里与底图差得多的地方，往外扩一圈再羽化；底图的黑环永远不在里面（眼睛挨着环时，外扩那圈也不能把生成图的环带进来）。"""
    diff = np.abs(arr(base) - arr(aligned)).max(axis=2)
    m = np.zeros(diff.shape, np.uint8)
    x0, y0, x1, y1 = box
    m[y0:y1, x0:x1] = (diff[y0:y1, x0:x1] > 30) * 255
    m = Image.fromarray(m).filter(ImageFilter.MaxFilter(15)).filter(ImageFilter.GaussianBlur(3))
    # 羽化之后再挖掉环：先挖再羽化的话，羽化又把生成图的环边混进来。两张图的环都挖掉（生成图的环偏一两像素，贴进来就是一道双环）
    ring = np.zeros(diff.shape, np.uint8)
    for img in (base, aligned):
        ys, xs = zip(*components(dark(img))[0][2])
        ring[list(ys), list(xs)] = 255
    m = arr(m)
    m[arr(Image.fromarray(ring).filter(ImageFilter.MaxFilter(9))) > 0] = 0
    return Image.fromarray(m.astype(np.uint8))


def patch(base, aligned, box, pose):
    m = mask_of(base, aligned, box)
    out = Image.composite(aligned, base, m)
    if not pose:
        # 只动眼睛：透明度只信底图
        out.putalpha(base.getchannel("A"))
    return out


def half_closed(base, blink, box):
    """半闭眼：每只眼睛（脸框里中等大小的暗块）上面 55% 换成闭眼帧同一处的像素（那里是肤色与眼皮那道线），下面留睁眼的下半截。"""
    a, b = arr(base).copy(), arr(blink)
    x0, y0, x1, y1 = box
    mask = np.zeros(a.shape[:2], bool)
    mask[y0:y1, x0:x1] = dark(base)[y0:y1, x0:x1]
    eyes = [c for c in components(mask) if 60 < c[0] < 3000]
    assert len(eyes) >= 2, f"脸框里找到 {len(eyes)} 只眼睛"
    for _, (ex0, ey0, ex1, ey1), _ in eyes[:2]:
        cut = ey0 + (ey1 - ey0) * 0.55
        for y in range(ey0 - 3, int(cut) + 2):
            k = min(1.0, max(0.0, cut - y))  # 切口那一行按覆盖比例混
            a[y, ex0 - 3:ex1 + 3] = a[y, ex0 - 3:ex1 + 3] * (1 - k) + b[y, ex0 - 3:ex1 + 3] * k
    return Image.fromarray(a.astype(np.uint8), "RGBA")


def build():
    src = {p.stem.removeprefix("mascot-cue-"): Image.open(p).convert("RGBA") for p in (SOURCES / "src").glob("*.png")}
    out: dict[str, Image.Image] = {}
    for frame in FRAMES:
        base = out.get(frame.base) or src[frame.base]
        if frame.kind == "copy":
            img = src[frame.name]
        elif frame.kind == "half":
            img = half_closed(base, out[f"{frame.base}-blink"], frame.box)
        else:
            pose = frame.kind == "pose"
            gen = Image.open(SOURCES / "gen" / f"{frame.name}.png").convert("RGBA")
            aligned = align(base, gen, "ring" if pose else "alpha")
            img = patch(base, tone(aligned, base), frame.box, pose)
            if pose:
                # 对齐本身也要对：生成图的环缩放后与底图的环一样宽、下沿一样高（换手欢呼曾整只小了一成，每圈缩两下）。
                # 不比上沿与高：换了姿势的生成图里环的倾角本来就差一点
                (a0, _, a1, b1), (c0, _, c1, d1) = ring_box(aligned), ring_box(base)
                off = exported(max(abs((a1 - a0) - (c1 - c0)), abs(b1 - d1)), base)
                assert off <= TOLERANCE, f"{frame.name}：对齐后黑环与底图差 {off:.1f}px（上限 {TOLERANCE}）"
        check(frame, img, base)
        out[frame.name] = img
        print(f"{frame.name:16} {frame.kind:5} {img.size}")
    return out


def check(frame, img, base):
    assert img.size == base.size, f"{frame.name}：画布 {img.size} 与底图 {base.size} 不同"
    if frame.kind == "copy":
        return
    def off(a, b): return exported(max(abs(p - q) for p, q in zip(a, b)), base)
    ring = off(ring_box(img), ring_box(base))
    assert ring <= TOLERANCE, f"{frame.name}：黑环外框与底图差 {ring:.1f}px（上限 {TOLERANCE}）"
    if frame.kind in ("eyes", "half"):
        whole = off(img.getbbox(), base.getbbox())
        assert whole <= TOLERANCE, f"{frame.name}：外框与底图差 {whole:.1f}px（上限 {TOLERANCE}）"


def exported(px, base):
    """底图里的像素数折成导出后（`WIDTH` 宽）的像素数：检查按用户看到的那一份算。"""
    return px * WIDTH / base.width


def write(frames: dict[str, Image.Image]):
    for folder, still in ((STILLS, True), (MOVING, False)):
        shutil.rmtree(folder, ignore_errors=True)
        folder.mkdir(parents=True)
        (folder / "Contents.json").write_text(xcode_json({"info": {"author": "xcode", "version": 1}}) + "\n")
        for frame in FRAMES:
            if frame.still != still:
                continue
            img = frames[frame.name]
            # 方画布、脚底贴下沿：各拍同一个缩放、同一条基线
            square = Image.new("RGBA", (img.width, img.width), (0, 0, 0, 0))
            square.paste(img, (0, img.width - img.height))
            img = square
            name = f"mascot-cue-{frame.name}"
            target = folder / f"{name}.imageset"
            target.mkdir()
            img.resize((WIDTH, WIDTH), Image.LANCZOS).save(target / f"{name}.png", optimize=True)
            contents = {
                "images": [{"filename": f"{name}.png", "idiom": "universal"}],
                "info": {"author": "xcode", "version": 1},
                "properties": {"preserves-vector-representation": False},
            }
            (target / "Contents.json").write_text("{\n" + ",\n".join(f'  "{k}" : {xcode_json(v)}' for k, v in contents.items()) + "\n}\n")


def xcode_json(value):
    """Xcode 自己写资源目录的那种格式（`"键" : 值`、一层一行）：重跑时 Contents.json 不因格式变动。"""
    if isinstance(value, dict):
        return "{ " + ", ".join(f'"{k}" : {xcode_json(v)}' for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "[ " + ", ".join(xcode_json(v) for v in value) + " ]"
    return json.dumps(value)


if __name__ == "__main__":
    write(build())
