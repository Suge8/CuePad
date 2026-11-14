"""xc.sh diag 读各台设备经 iCloud 送到这台 Mac 的诊断（DiagnosticInbox.swift 落的文件），用法与目录约定见 device_diag.py 头注释。"""
import json
import os
import re
import subprocess
import sys

from diag_report import ARCHIVES, dsyms, shown, summarize

INBOX = os.environ.get("CUEPAD_DIAG_DIR") or os.path.expanduser("~/Library/Logs/CuePad")
ACTIVITY = "activity.json"  # 同 DiagnosticArchive.activity：手机实时活动的取证
SUMMARY = ".summary.json"  # 同 DiagnosticInbox.summary(of:)


def folders():
    """收件目录下每台设备一个目录（以点开头的是收件进度）。"""
    if not os.path.isdir(INBOX):
        sys.exit(f"{shown(INBOX)} 还没有：这台 Mac 上的 CuePad 还没收到过别的设备的诊断（要登着同一个 iCloud、开着同步）。"
                 "读隔离实例的给 CUEPAD_DIAG_DIR=<库目录>/Logs")
    return sorted(d for d in os.listdir(INBOX) if not d.startswith(".") and os.path.isdir(f"{INBOX}/{d}"))


def overview():
    names = folders()
    print(f"{shown(INBOX)}：{len(names)} 台设备" + ("" if names else "（还没收到过）"))
    for name in names:
        files = sorted((f for f in os.listdir(f"{INBOX}/{name}") if f != ACTIVITY and not f.endswith(SUMMARY)), reverse=True)
        logs = [f for f in files if f.endswith(".log")]
        print(f"  {name}：诊断 {len(files) - len(logs)} 份、日志 {len(logs)} 份；最新 {files[0] if files else '无'}")


def device_dir(wanted):
    names = folders()
    hits = [n for n in names if n == wanted] or [n for n in names if n.startswith(wanted)]
    if len(hits) != 1:
        sys.exit(f"{shown(INBOX)} 里对上「{wanted}」的设备有 {len(hits)} 台；有这些：{'、'.join(names) or '无'}")
    return f"{INBOX}/{hits[0]}"


def inbox(wanted, full):
    folder = device_dir(wanted)
    files = sorted((f for f in os.listdir(folder) if f != ACTIVITY and not f.endswith(SUMMARY)), reverse=True)
    reports = [r for f in files if f.endswith(".json") for r in metrickit(f"{folder}/{f}")]
    print(f"{shown(folder)}：诊断 {len(reports)} 份")
    summarize(reports)
    logs = [f for f in files if f.endswith(".log")]
    print(f"\n日志 {len(logs)} 份" + ("" if logs else "：设置里点\"把最近日志发到 Mac\"送一份；主线程卡住后恢复的，卡住前后那段自动附上"))
    for name in logs:
        text = open(f"{folder}/{name}", encoding="utf-8", errors="replace").read()
        lines = text.splitlines()
        levels = {}
        for line in lines[1:]:
            parts = line.split(" ", 3)
            if len(parts) > 2:
                levels[parts[2]] = levels.get(parts[2], 0) + 1
        print(f"  {shown(folder + '/' + name)}\n    {lines[0] if lines else '（空）'}\n    " + "、".join(f"{k} {v}" for k, v in sorted(levels.items())))
        if full:
            print("\n".join(lines[1:]))
    if os.path.exists(f"{folder}/{ACTIVITY}"):
        events = json.load(open(f"{folder}/{ACTIVITY}"))["events"]
        print(f"\n实时活动取证 {len(events)} 条（最近 7 天、至多 96 条）：{shown(folder + '/' + ACTIVITY)}")
        keys = ("action", "activity", "reason", "sourceAt", "contentTag", "tokenTag", "foreground", "errorDomain", "errorCode")
        for event in events if full else events[-10:]:
            print(f'  {event["at"]} ' + " ".join(f"{k}={event[k]}" for k in keys if event.get(k) is not None))


def metrickit(path):
    """App 收下时在旁边落的要点（DiagnosticInbox.swift 的 <文件>.summary.json，同 CrashReport.Summary），这里只符号化。"""
    summary = path + SUMMARY
    if not os.path.exists(summary):
        print(f"  {shown(path)} 没有要点（更新 Mac 上的 CuePad 前收的；删掉收件目录里的 .inbox.json 让它从头收一遍）")
        return []
    found = []
    for r in json.load(open(summary)):
        frames = [{"offset": None, "address": None, "uuid": "", **f, "symbol": None, "base": None} for f in r["frames"]]  # Swift 不写空值
        platform = "mac" if (r.get("os") or "").startswith("macOS") else "ios"
        found.append({"file": path, "date": r["date"], "who": "CuePad", "app": r.get("app") or "", "title": r["title"],
                      "reasons": r["reasons"], "explanation": r.get("explanation"), "frames": frames, "frames_title": r["framesTitle"],
                      "symbols": symbolicate_metrickit(frames, platform, r.get("build") or ""), "trail": r["trail"], "id": os.path.basename(path)})
    return found


def symbolicate_metrickit(frames, platform, build):
    """帧的 UUID 对上归档里的 dSYM 就是 CuePad 自己的，用 atos 还原。offsetIntoBinaryTextSegment 按文档是二进制内的偏移，
    但有报告说早期系统在这里放的是二进制的载入地址：大到像地址时当载入地址用，否则载入地址是 address − 偏移。"""
    found = dsyms(platform, build)
    notes, used = [], set()
    for f in frames:
        dwarf = found.get(f["uuid"])
        if not dwarf or f["offset"] is None:
            continue
        f["own"] = True
        address = f["address"] if f["address"] is not None else 0x100000000 + f["offset"]
        base = f["offset"] if f["offset"] >= 0x100000000 else address - f["offset"]
        line = subprocess.run(["xcrun", "atos", "-arch", "arm64", "-o", dwarf, "-l", hex(base), hex(address)],
                              capture_output=True, text=True, check=True).stdout.strip()
        f["symbol"] = re.sub(r" \(in [^)]+\)", "", line)
        if f["offset"] >= 0x100000000:
            f["offset"] = address - base
        used.add((f["binary"], dwarf, f["uuid"]))
    for binary, dwarf, uuid in sorted(used):
        notes.append(f"{binary} 按 {shown(dwarf.split('/dSYMs/')[0])} 还原（UUID {uuid}）")
    if any(f["own"] and not f["symbol"] for f in frames):
        notes.append(f"CuePad 的帧没有对上的 dSYM（找的是 {shown(ARCHIVES)}/*/CuePad {platform} {build}*.xcarchive）")
    return notes
