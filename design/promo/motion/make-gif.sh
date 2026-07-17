#!/bin/bash
# 一键投送演示 GIF：段1(record-ui.mjs 的 screencast 帧) + 段2(terminal.tape) → demo-dispatch.gif
# 前置：/tmp/cuepad-promo/frames/（record-ui.mjs 产物）+ design/promo/motion/terminal.mp4（vhs 产物）
set -euo pipefail
cd "$(dirname "$0")/../../.."

WORK=/tmp/cuepad-promo
OUT=design/promo/motion/demo-dispatch.gif

# 段1：screencast 帧按真实时间戳成片
ffmpeg -y -v error -f concat -safe 0 -i "$WORK/frames/concat.txt" \
  -vf "fps=24,scale=1200:760" -pix_fmt yuv420p "$WORK/ui.mp4"

# 拼接（统一 24fps）
ffmpeg -y -v error -i "$WORK/ui.mp4" -i design/promo/motion/terminal.mp4 \
  -filter_complex "[0:v]fps=24[a];[1:v]fps=24[b];[a][b]concat=n=2:v=1[v]" -map "[v]" \
  -pix_fmt yuv420p "$WORK/demo-full.mp4"

# 两趟调色板法出 GIF（960 宽 12fps）
ffmpeg -y -v error -i "$WORK/demo-full.mp4" \
  -vf "fps=12,scale=960:-1:flags=lanczos,palettegen" "$WORK/palette.png"
ffmpeg -y -v error -i "$WORK/demo-full.mp4" -i "$WORK/palette.png" \
  -filter_complex "fps=12,scale=960:-1:flags=lanczos[x];[x][1:v]paletteuse" "$OUT"

ls -lh "$OUT"
