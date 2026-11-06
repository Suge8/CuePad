#!/usr/bin/env python3
"""把 hmr_drive.py 的写入时刻与 App 日志（LP 行）配对：css → 第一条 sig 里样式长度变化的 changed；js → 第一条 sig 以 "Edit i|" 开头的 load。
用法：hmr_report.py <edits.log> <app-sim.log>"""
import json, re, sys, statistics
edits = [l.split() for l in open(sys.argv[1]) if l.startswith("EDIT")]
events = []
for l in open(sys.argv[2]):
    m = re.match(r"LP (\d+) js (\{.*\})$", l.strip())
    if m:
        e = json.loads(m.group(2)); events.append(e)
res = {"css": [], "js": []}
for _, kind, i, t in edits:
    t = int(t); i = int(i)
    for e in events:
        if e["t"] < t: continue
        if kind == "css" and e["type"] == "changed" and not e["sig"].startswith(f"Edit {i}|") or kind == "css" and e["type"] == "changed":
            res["css"].append(e["t"] - t); break
        if kind == "js" and e["type"] == "load" and e["sig"].startswith(f"Edit {i}|"):
            res["js"].append(e["t"] - t); break
for k, v in res.items():
    if v: print(f"{k}: n={len(v)} 中位={statistics.median(v)}ms 最小={min(v)} 最大={max(v)} 全部={v}")
