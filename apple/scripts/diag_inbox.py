"""xc.sh diag 读各台设备经 iCloud 送到这台 Mac 的诊断（DiagnosticInbox.swift 落的文件），用法与目录约定见 device_diag.py 头注释。"""
import datetime
import json
import os
import re
import subprocess
import sys

from diag_report import ARCHIVES, EXPLAIN, WATCHDOG, WATCHDOG_EVENTS, dsyms, pick, shown, summarize

INBOX = os.environ.get("CUEPAD_DIAG_DIR") or os.path.expanduser("~/Library/Logs/CuePad")
KINDS = {"crashDiagnostics": "崩溃", "hangDiagnostics": "卡死", "cpuExceptionDiagnostics": "CPU 异常",
         "diskWriteExceptionDiagnostics": "磁盘写入异常"}  # 同 CrashReport.Kind，按这个顺序
EXCEPTIONS = {1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT",
              10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD"}
SIGNALS = {4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE", 15: "SIGTERM"}


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
        files = sorted(os.listdir(f"{INBOX}/{name}"), reverse=True)
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
    files = sorted(os.listdir(folder), reverse=True)
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


def metrickit(path):
    """一份 MetricKit 包（或本机记下的主线程卡住）解成要点：同 CrashReport.reports(file:json:)。"""
    body = json.load(open(path))
    name = os.path.basename(path)
    if "cuepadFreeze" in body:
        note = body["cuepadFreeze"]
        seconds = note.get("seconds")
        reason = f"主线程 {round(seconds)} 秒没回到事件循环，之后恢复了" if seconds is not None else "主线程卡住，没等到恢复 App 就被结束了"
        return [{"file": path, "date": f'{datetime.datetime.fromisoformat(note["start"]).astimezone():%Y-%m-%d %H:%M:%S}', "who": "CuePad",
                 "app": " · ".join((note["version"], note["device"], note["os"])), "title": "主线程卡住", "reasons": [reason],
                 "explanation": None, "frames": [], "frames_title": "", "symbols": [],
                 "trail": [f'所在页：{note["page"]}', *note["actions"]], "id": name}]
    found = []
    for key, kind in KINDS.items():
        for item in body.get(key, []):
            meta = item.get("diagnosticMetaData", {})
            exception = EXCEPTIONS.get(meta.get("exceptionType"), f'EXC_{meta["exceptionType"]}' if "exceptionType" in meta else None)
            signal = SIGNALS.get(meta.get("signal"), f'SIG{meta["signal"]}' if "signal" in meta else None)
            objc = meta.get("objectiveCexceptionReason") or {}
            thrown = ": ".join(p for p in (objc.get("exceptionName"), objc.get("composedMessage")) if p)
            termination = meta.get("terminationReason", "")
            version = f'{meta["appVersion"]}（{meta.get("appBuildVersion", "?")}）' if meta.get("appVersion") else None
            platform = "mac" if meta.get("osVersion", "").startswith("macOS") else "ios"
            frames = stack(item.get("callStackTree"))
            found.append({"file": path, "date": body.get("timeStampEnd", ""), "who": "CuePad",
                          "app": " · ".join(p for p in (version, meta.get("deviceType"), meta.get("osVersion")) if p),
                          "title": kind + (f" · {exception}" + (f"（{signal}）" if signal else "") if exception else ""),
                          "reasons": [r for r in (thrown, termination) if r], "explanation": explain(termination),
                          "frames": frames, "frames_title": "崩溃线程：" if key == "crashDiagnostics" else "主线程：",
                          "symbols": symbolicate_metrickit(frames, platform, meta.get("appBuildVersion", "")), "trail": []})
    return found


def explain(termination):
    code = re.search(r"code:(0x[0-9A-Fa-f]+)", termination)
    if not code:
        return None
    code = int(code[1], 16)
    if code == 0x8BADF00D:
        event = re.search(r"WatchdogEvent: ([\w-]+)", termination)
        return WATCHDOG + (WATCHDOG_EVENTS.get(event[1], f"（{event[1]}）") if event else "")
    return EXPLAIN.get(code)


def stack(tree):
    """同 CrashReport.frames(of:)：被标记的线程（没有就第一条），从崩溃处顺着调用者往下。"""
    stacks = (tree or {}).get("callStacks", [])
    chosen = next((s for s in stacks if s.get("threadAttributed")), stacks[0] if stacks else {})
    frames, node = [], (chosen.get("callStackRootFrames") or [None])[0]
    while node:
        uuid = node.get("binaryUUID", "").upper()
        frames.append({"binary": node.get("binaryName") or uuid[:8] or "?", "offset": node.get("offsetIntoBinaryTextSegment"),
                       "address": node.get("address"), "uuid": uuid, "own": (node.get("binaryName") or "").startswith("CuePad"),
                       "symbol": None, "base": None})
        node = (node.get("subFrames") or [None])[0]
    return pick(frames)


def symbolicate_metrickit(frames, platform, build):
    """帧的 UUID 对上归档里的 dSYM 就是 CuePad 自己的，用 atos 还原。offsetIntoBinaryTextSegment 按文档是二进制内的偏移，
    但有报告说早期系统在这里放的是二进制的载入地址：大到像地址时当载入地址用，否则载入地址是 address − 偏移。实测样本见 docs/diagnose.md。"""
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
