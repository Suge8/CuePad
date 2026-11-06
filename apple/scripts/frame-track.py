#!/usr/bin/env python3
"""逐帧量录屏里几样东西的横向位置：看开合、跨临界宽这类滑动里每个元素是不是从旧处连续走到新处（docs/perf.md「开合的逐帧量法」）。

用法：uv run --with numpy python3 apple/scripts/frame-track.py 片.mov 名:y:x0:x1[:高] … [--ref=帧号] [--rows=1] [--axis=y]
  --axis=y 量竖向位置（整卡进出时对话让没让、跳没跳）：每样写成 名:x:y0:y1[:宽]，横竖对调，其余同。
  片.mov 是 xc.sh rec 录的（Mac 按窗口录，Retina 屏上 2x；模拟器横屏录的按转正后的画面量）；坐标都是点、相对窗口左上，--scale 改倍数（默认 2）。
  每样东西在参考帧（默认第 0 帧）里取 y 上下各 高/2（默认 12）、x0～x1 的一条做模板，之后每帧在同一条带里按最小绝对差找它，
  只在上一帧位置左右 --search（默认 420）点内找。挑纹理清楚的字：会动的头像、低对比的空块会认到别处，读成跳。
  输出每样东西按"动—停"切的段（连着 6 帧不到 0.25 点算停）：起止位置、最大单步与反向步（与这一段总方向相反、超过 0.5 点的一步）；
  --rows=1 另列逐帧的位置。中途反向的录法（-CuePadSidebarCycle fast）反向步是按的那一下，看逐帧位置有没有跳回旧处。
帧号按录屏里实际的帧（-fps_mode passthrough），录屏只在画面变时出帧，两帧的时刻差大是那一段屏上没变（主线程忙、合成没交新帧）。
用 numpy 做模板匹配：几百帧 × 整窗宽的滑窗比较，纯 Python 要几分钟。
"""
import json
import subprocess
import sys

import numpy as np

args = [a for a in sys.argv[1:] if not a.startswith("--")]
opts = dict(a[2:].split("=", 1) for a in sys.argv[1:] if a.startswith("--"))
if len(args) < 2:
    sys.exit(__doc__)
movie, specs = args[0], args[1:]
scale = float(opts.get("scale", 2))
ref = int(opts.get("ref", 0))
search = int(float(opts.get("search", 420)) * scale)
vertical = opts.get("axis") == "y"
STILL_FRAMES = 6
STILL_PT = 0.25
REVERSE_PT = 0.5


def probe(entries):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", entries, "-of", "csv=p=0", movie],
                         capture_output=True, text=True, check=True).stdout
    return [v.strip(",") for v in out.split() if v.strip(",")]


times = [float(t) for t in probe("frame=pts_time")]
# 横屏的模拟器录出来是竖着的像素加一个转 90° 的显示矩阵，ffmpeg 解出来已转正：宽高要对调
width, height = map(int, probe("stream=width,height")[0].split(","))
if abs(int(float((probe("stream_side_data=rotation") or ["0"])[0]))) == 90:
    width, height = height, width


def track(spec):
    parts = spec.split(":")
    y, x0, x1 = float(parts[1]), float(parts[2]), float(parts[3])
    band = float(parts[4]) if len(parts) > 4 else 12
    # 条带的起点与厚度取偶数：yuv420 的画面按 2 像素对齐裁
    top, rows = int((y - band / 2) * scale) // 2 * 2, int(band * scale) // 2 * 2
    crop = f"crop={rows}:{height}:{top}:0" if vertical else f"crop={width}:{rows}:0:{top}"
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", movie, "-fps_mode", "passthrough", "-vf", crop,
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    frames = np.frombuffer(raw, dtype=np.uint8)
    frames = (frames.reshape(-1, height, rows).transpose(0, 2, 1) if vertical else frames.reshape(-1, rows, width)).astype(np.int16)
    length = frames.shape[2]
    left, right = int(x0 * scale), int(x1 * scale)
    template, span = frames[ref][:, left:right], right - left
    found, last = [], left
    for frame in frames:
        lo, hi = max(0, last - search), min(length - span, last + search)
        windows = np.lib.stride_tricks.sliding_window_view(frame[:, lo:hi + span], span, axis=1)
        last = lo + int(np.abs(windows - template[:, None, :]).sum(axis=(0, 2)).argmin())
        found.append(last / scale)
    return found


def segments(xs):
    found, start, still = [], None, 0
    for i in range(1, len(xs)):
        if abs(xs[i] - xs[i - 1]) >= STILL_PT:
            start = i - 1 if start is None else start
            still = 0
        elif start is not None:
            still += 1
            if still >= STILL_FRAMES:
                found.append((start, i - still))
                start, still = None, 0
    return found + ([(start, len(xs) - 1)] if start is not None else [])


tracks = {spec.split(":")[0]: track(spec) for spec in specs}
count = min(len(v) for v in tracks.values())
if opts.get("rows"):
    print("帧 时刻 " + " ".join(tracks))
    for i in range(count):
        print(i, round(times[i], 4) if i < len(times) else "-", *(v[i] for v in tracks.values()))
report = {}
for name, xs in tracks.items():
    report[name] = []
    for a, b in segments(xs[:count]):
        steps = [xs[i] - xs[i - 1] for i in range(a + 1, b + 1)]
        sign = 1 if xs[b] >= xs[a] else -1
        report[name].append({"帧": f"{a}-{b}", "起": xs[a], "止": xs[b], "最大单步": round(max(map(abs, steps)), 1),
                             "反向步": [round(s, 1) for s in steps if s * sign < -REVERSE_PT]})
print(json.dumps(report, ensure_ascii=False, indent=1))
