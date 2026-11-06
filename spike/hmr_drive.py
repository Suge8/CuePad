#!/usr/bin/env python3
"""改 Vite 模板的文件并打下写入前一刻（毫秒），与 App 日志里页面的 changed/load 时刻对照。
用法：hmr_drive.py <vite-app 目录> <轮数> [间隔秒=2]；每轮改一次 style.css（CSS 热替换）、一次 main.js（整页刷新），结束还原。"""
import re, sys, time, pathlib
d = pathlib.Path(sys.argv[1]) / "src"; n = int(sys.argv[2]); gap = float(sys.argv[3]) if len(sys.argv) > 3 else 2
css, js = d / "style.css", d / "main.js"
css0, js0 = css.read_text(), js.read_text()
ms = lambda: int(time.time() * 1000)
try:
    for i in range(1, n + 1):
        time.sleep(gap); t = ms(); css.write_text(css0 + f"\n/* lp {i} {'x' * i} */\n"); print("EDIT css", i, t, flush=True)
        time.sleep(gap); t = ms(); js.write_text(re.sub(r"<h1>[^<]*</h1>", f"<h1>Edit {i}</h1>", js0)); print("EDIT js", i, t, flush=True)
finally:
    time.sleep(gap); css.write_text(css0); js.write_text(js0)
