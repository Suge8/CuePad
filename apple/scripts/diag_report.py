"""xc.sh diag 的共用部分：人话表、要点的格式（同 App 里"导出诊断"，DiagnosticSummary.swift）、按发布归档的 dSYM 找符号。"""
import glob
import json
import os
import re
import subprocess

ARCHIVES = os.path.expanduser("~/Library/Developer/Xcode/Archives")
TOP_FRAMES, OWN_FRAMES, SHOWN_TIMES = 8, 4, 5  # 同 CrashReport.topFrames、ownFrames 与 DiagnosticSummary.shownTimes
# 人话照抄 CrashReport.swift 的 Termination（App 的导出诊断用它）：改一边就改另一边
EXPLAIN = {
    0xDEAD10CC: "进后台挂起时还握着共享的文件锁（如 SQLite），被系统结束",
    0xC00010FF: "设备过热，被系统结束",
    0xDEADFA11: "用户强制退出",
    0xBAADCA11: "收到 VoIP 推送后没向系统报来电，被系统结束",
}
WATCHDOG = "看门狗：主线程太久没响应，被系统结束"
WATCHDOG_EVENTS = {
    "process-exit": "（系统要结束 App 时 5 秒内没退出：多半主线程在那之前就卡住了，比如从后台划掉卡住的 App）",
    "scene-update": "（切前后台、场景更新时没按时答复）",
    "scene-create": "（建窗口时没按时答复）",
    "process-launch": "（启动太久）",
}
RESOURCE_EVENTS = {"cpu usage": "CPU 异常", "disk writes": "磁盘写入异常", "wakeups": "唤醒过多"}


def shown(path):
    """检出里的写相对路径，别处写全路径。"""
    return os.path.relpath(path) if os.path.abspath(path).startswith(os.getcwd() + "/") else path

def pick(frames):
    """同 CrashReport.frames(of:)：顶上 TOP_FRAMES 帧，更深处 CuePad 自己的帧再补至多 OWN_FRAMES 个。"""
    return frames[:TOP_FRAMES] + [f for f in frames[TOP_FRAMES:] if f["own"]][:OWN_FRAMES]


_dsyms = {}


def dsyms(platform, build):
    """UUID → 归档里 dSYM 的 DWARF 文件；只看这个平台、这个构建号的归档（release 脚本按"CuePad <平台> <构建号>"命名）。"""
    key = (platform, build)
    if key not in _dsyms:
        found = {}
        for dwarf in glob.glob(f"{ARCHIVES}/*/CuePad {platform} {glob.escape(build)}*.xcarchive/dSYMs/*.dSYM/Contents/Resources/DWARF/*"):
            listing = subprocess.run(["dwarfdump", "--uuid", dwarf], capture_output=True, text=True).stdout
            for uuid in re.findall(r"UUID: ([0-9A-F-]+)", listing):
                found[uuid] = dwarf
        _dsyms[key] = found
    return _dsyms[key]

def summarize(reports):
    """同 DiagnosticSummary.text：同一种（类型、原因、前几帧）并成一条，计次数，最新的在前。"""
    if not reports:
        return
    groups = {}
    for r in reports:
        # 原因里的数字抹掉再比（同 CrashReport.cause）：CPU 用时、地址每次都不同
        signature = (r["who"], r["title"], r["explanation"], [re.sub(r"\d+", "#", x) for x in r["reasons"][:1]], r.get("trail", [])[:1], [(f["binary"], f["offset"]) for f in r["frames"]])
        groups.setdefault(json.dumps(signature, ensure_ascii=False), []).append(r)
    ordered = sorted(groups.values(), key=lambda g: max(r["date"] for r in g), reverse=True)
    print(f"\n诊断摘要：{len(reports)} 份，{len(ordered)} 种")
    for group in ordered:
        group.sort(key=lambda r: r["date"], reverse=True)
        r = group[0]
        print(f'\n{r["who"]} {r["title"]}' + (f" × {len(group)}" if len(group) > 1 else ""))
        times = [g["date"] for g in group]
        print(f'时间：{"、".join(times[:SHOWN_TIMES])}' + ("…" if len(times) > SHOWN_TIMES else ""))
        versions = sorted({g["app"] for g in group if g["app"]})
        if versions:
            print(f'版本：{"、".join(versions)}')
        if r["explanation"]:
            print(f'说明：{r["explanation"]}')
        reasons = list(dict.fromkeys(x for g in group for x in g["reasons"]))  # 同一种各次的原因原文，同 DiagnosticSummary
        for reason in reasons[:3]:
            print(f"原因：{reason}")
        if len(reasons) > 3:
            print("…")
        for step in r.get("trail", []):
            print(f"  {step}")
        if r["frames"]:
            print(r["frames_title"])
            for f in r["frames"]:
                place = f'{f["binary"]} +{f["offset"]:#x}' if f["offset"] is not None else f["binary"]
                print(f'  {place}' + (f'  {f["symbol"]}' if f["symbol"] else "") + ("  ← CuePad" if f["own"] else ""))
        for note in r["symbols"]:
            print(f"符号：{note}")
        print(f'文件：{"、".join(shown(g["file"]) for g in group)}')
