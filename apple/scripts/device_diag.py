#!/usr/bin/env python3
"""xc.sh diag：连着这台 Mac 的真机上 CuePad 的崩溃报告与运行日志，只读（不装、不起停 App、不读 App 的数据、不改设置、不上传）。
用法：xc.sh diag ios crashes [all]                      拉手机上 CuePad 的崩溃报告（连同记下 CuePad 被内存回收的 JetsamEvent）到
                                                      apple/.derived/diag/<UDID>/，用发布归档的 dSYM 符号化，打出要点；all 连系统别的报告一起拉、一起解析
      xc.sh diag ios logs [跟的秒数=60] [回看的秒数=0]       窗口是 [现在−回看, 现在+跟]：先等跟的秒数（用户这时在手机上复现），再取手机的日志、
                                                      只留窗口里 CuePad 的（进程名 CuePad 开头、子系统是 App 身份，加 runningboardd 关于它的起停），写进同一目录
      xc.sh diag ips <文件.ips>…                         解析、符号化本机已有的报告（用户发来的，Mac 的 ~/Library/Logs/DiagnosticReports）
崩溃报告走 devicectl（Xcode 自带；无线连接也行，不要 root）：systemCrashLogs 域的列出与拷出，拷出不删手机上的。
日志 devicectl 给不了：它没有日志流，device sysdiagnose 要管理员密码（内部调 sudo）；log collect --device 要 root；
xctrace 的 Logging 模板认无线连接的手机为离线。pymobiledevice3 无线下要么另配对一次（手机上点信任），要么搭 remoted 的隧道（--native），
那样会把 Xcode 与 devicectl 的连接挤掉（它的 network-stacks 文档、#1994）。所以日志用 idevicesyslog（Homebrew 的 libimobiledevice，不要 root）
经 usbmuxd 取 os_trace_relay 打包的 logarchive：手机要用线连着，或在 Finder 里开了「通过 Wi-Fi 连接时显示」（usbmux 函数）。
logarchive 留在 last.logarchive，换窗口、换过滤再截用 log show --archive。
手机选 CUEPAD_DIAG_DEVICE（名字或 UDID）；没给时取唯一一台配对过的真机。要点的格式与 App 里"导出诊断"同一套（DiagnosticSummary.swift）。"""
import datetime
import glob
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import time

sys.dont_write_bytecode = True
from app_env import APPLE, BUNDLE_ID

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
LOG_PREDICATE = (f'process BEGINSWITH "CuePad" OR subsystem BEGINSWITH "{BUNDLE_ID}" '
                 f'OR (process == "runningboardd" AND eventMessage CONTAINS "{BUNDLE_ID}")')


def devicectl(*args, timeout=None):
    """devicectl 的 JSON 结果；失败时带它的报错退出。手机锁屏久了、换了网络或刚重启时报连不上（usage assertion）。"""
    with tempfile.NamedTemporaryFile(suffix=".json") as out:
        done = subprocess.run(["xcrun", "devicectl", *args, "-q", "-j", out.name], capture_output=True, text=True, timeout=timeout)
        if done.returncode:
            sys.exit(f"devicectl {' '.join(args[:3])} 失败：{(done.stderr or done.stdout).strip()}\n"
                     "连不上就请用户解锁手机、和这台 Mac 连同一个网络；不在身边就请用户在设置里导出诊断（docs/diagnose.md）")
        return json.load(open(out.name))["result"]


def device():
    devices = [d["properties"] for d in devicectl("list", "devices")["devices"]]
    devices = [d for d in devices if d["hardware"].get("reality") == "physical" and d["connection"].get("pairingState") == "paired"]
    wanted = os.environ.get("CUEPAD_DIAG_DEVICE")
    if wanted:
        devices = [d for d in devices if wanted in (d["state"]["name"], d["hardware"]["udid"])]
    if len(devices) != 1:
        names = "、".join(f'{d["state"]["name"]}（{d["hardware"]["udid"]}）' for d in devices)
        sys.exit(f"配对过的真机有 {len(devices)} 台{('：' + names) if names else ''}；用 CUEPAD_DIAG_DEVICE=<名字或 UDID> 指定一台。"
                 "手机不在身边就请用户在设置里导出诊断（docs/diagnose.md）")
    return devices[0]["hardware"]["udid"], devices[0]["state"]["name"]


def shown(path):
    """检出里的写相对路径，别处写全路径。"""
    return os.path.relpath(path) if os.path.abspath(path).startswith(os.getcwd() + "/") else path


def out_dir(udid):
    path = f"{APPLE}/.derived/diag/{udid}"
    os.makedirs(path, exist_ok=True)
    return path


# ---------- 崩溃报告 ----------

def crashes(everything):
    udid, name = device()
    target = out_dir(udid)
    files = [f for f in devicectl("device", "info", "files", "-d", udid, "--domain-type", "systemCrashLogs")["files"]
             if f["relativePath"].endswith(".ips")]
    wanted = [f for f in files if everything or os.path.basename(f["relativePath"]).startswith(("CuePad", "JetsamEvent"))]
    print(f"{name}：报告 {len(files)} 份，拉取 {len(wanted)} 份到 {shown(target)}")
    paths = []
    for f in wanted:
        local = f"{target}/{os.path.basename(f['relativePath'])}"
        if not os.path.exists(local) or os.path.getsize(local) != f["metadata"]["size"]:
            devicectl("device", "copy", "from", "-d", udid, "--domain-type", "systemCrashLogs",
                      "--source", f["relativePath"], "--destination", local)
        paths.append(local)
    reports = [r for p in paths for r in parse(p, everything)]
    if not reports:
        others = sorted(os.path.basename(f["relativePath"]) for f in files)
        print("手机上没有 CuePad 的崩溃报告" + (f"；别的：{'、'.join(others)}（all 一起拉）" if others else ""))
    summarize(reports)


def parse(path, everything=True):
    """一份 .ips 解成要点（可能没有）：头一行是 JSON 的元数据，其后是 JSON（崩溃、Jetsam）或文字（CPU、磁盘写入等资源报告）。"""
    head, _, body = open(path, encoding="utf-8", errors="replace").read().partition("\n")
    head = json.loads(head)
    try:
        body = json.loads(body)
    except ValueError:
        return [resource(path, head, body)]
    if "processes" in body:
        return jetsam(path, head, body, everything)
    if head.get("bug_type") == "309":
        return [crash(path, head, body)]
    return [report(path, head, f'报告（bug_type {head.get("bug_type")}）', body.get("modelCode"))]


def report(path, head, kind, device, **rest):
    version = f'{head.get("app_version")}（{head.get("build_version", "?")}）' if head.get("app_version") else None
    stamp = re.match(r"(\S+ \d\d:\d\d:\d\d)\S* ([+-]\d\d)(\d\d)", head.get("timestamp", ""))  # "2026-11-09 20:50:29.00 +0800"
    return {"file": path, "date": f"{stamp[1]} {stamp[2]}:{stamp[3]}" if stamp else "", "who": head.get("app_name") or head.get("name"),
            "app": " · ".join(p for p in (version, device, head.get("os_version")) if p),
            "title": kind, "reasons": [], "explanation": None, "frames": [], "frames_title": "崩溃线程：", "symbols": [], **rest}


def crash(path, head, body):
    exc, term = body.get("exception", {}), body.get("termination", {})
    images = body.get("usedImages", [])
    title = "崩溃" + (f' · {exc["type"]}' + (f'（{exc["signal"]}）' if exc.get("signal") else "") if exc.get("type") else "")
    reasons, explanation = [], None
    code = term.get("code")
    if code is not None and term.get("namespace") != "SIGNAL":  # 信号已在标题里
        texts = " ".join(term.get("reasons", []) + [term.get("indicator", "")])
        reasons.append(" ".join(p for p in (term.get("namespace"), f"code:{code:#x}", term.get("indicator")) if p))
        reasons += term.get("reasons", [])
        event = re.search(r"WatchdogEvent: ([\w-]+)", texts)
        if code == 0x8BADF00D:
            explanation = WATCHDOG + (WATCHDOG_EVENTS.get(event[1], f"（{event[1]}）") if event else "")
        else:
            explanation = EXPLAIN.get(code)
    for owner, lines in (body.get("asi") or {}).items():
        reasons += [f"{owner}：{line}" for line in lines]
    if exc.get("message"):
        reasons.append(exc["message"])
    thrown = body.get("lastExceptionBacktrace")
    threads = body.get("threads", [])
    stack = thrown or next((t["frames"] for t in threads if t.get("triggered")), threads[0]["frames"] if threads else [])
    frames = pick([frame(images, f) for f in stack])
    return report(path, head, "崩溃", body.get("modelCode"), title=title, reasons=reasons, explanation=explanation,
                  frames=frames, frames_title="异常抛出处：" if thrown else "崩溃线程：", symbols=symbolicate(frames, head))


def frame(images, f):
    image = images[f["imageIndex"]] if "imageIndex" in f else {}
    name = image.get("name") or "?"
    own = ".app/" in image.get("path", "") and not image.get("path", "").startswith("/System/")
    symbol = f.get("symbol")
    if symbol and f.get("sourceFile"):
        symbol += f' ({f["sourceFile"]}:{f.get("sourceLine", "?")})'
    return {"binary": name, "offset": f.get("imageOffset"), "own": own, "symbol": symbol,
            "uuid": image.get("uuid", "").upper(), "base": image.get("base")}


def pick(frames):
    """同 CrashReport.frames(of:)：顶上 TOP_FRAMES 帧，更深处 CuePad 自己的帧再补至多 OWN_FRAMES 个。"""
    return frames[:TOP_FRAMES] + [f for f in frames[TOP_FRAMES:] if f["own"]][:OWN_FRAMES]


def symbolicate(frames, head):
    """CuePad 自己没带符号的帧（发布构建去了符号）按 UUID 找发布归档里的 dSYM，atos 还原成函数与源码行；返回用了哪份、缺哪份。"""
    own = [f for f in frames if f["own"] and not f["symbol"] and f["offset"] is not None and f["base"] is not None]
    platform = "mac" if head.get("os_version", "").startswith("macOS") else "ios"
    build = head.get("build_version", "")
    notes = []
    for uuid in sorted({f["uuid"] for f in own}):
        group = [f for f in own if f["uuid"] == uuid]
        dwarf = dsyms(platform, build).get(uuid)
        if not dwarf:
            notes.append(f"{group[0]['binary']} 的 UUID {uuid} 没有对上的 dSYM（找的是 {shown(ARCHIVES)}/*/CuePad {platform} {build}*.xcarchive）")
            continue
        addresses = [hex(f["base"] + f["offset"]) for f in group]
        lines = subprocess.run(["xcrun", "atos", "-arch", "arm64", "-o", dwarf, "-l", hex(group[0]["base"]), *addresses],
                               capture_output=True, text=True, check=True).stdout.splitlines()
        for f, line in zip(group, lines):
            f["symbol"] = re.sub(r" \(in [^)]+\)", "", line)
        notes.append(f"{group[0]['binary']} 按 {shown(dwarf.split('/dSYMs/')[0])} 还原（UUID {uuid}）")
    return notes


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


def jetsam(path, head, body, everything):
    """系统内存紧张时一次回收一批进程，记在一份 JetsamEvent 里；只认 CuePad（及其扩展）带了回收原因的。"""
    page = body.get("memoryStatus", {}).get("pageSize", 16384)
    found = []
    for p in body["processes"]:
        if p.get("reason") and (everything or p.get("name", "").startswith("CuePad")):
            memory = f'{p.get("rpages", 0) * page / 2**20:.0f} MB'
            found.append(report(path, {**head, "app_name": p.get("name")}, "内存回收",
                                body.get("product"), title=f'内存回收（Jetsam）· {p["reason"]}', reasons=[f'{p.get("name")} 占用 {memory}']))
    return found


def resource(path, head, text):
    field = dict(re.findall(r"^(Event|Action taken|Writes|CPU|Wakeups|Hardware model):\s+(.*)$", text, re.M))
    kind = RESOURCE_EVENTS.get(field.get("Event", ""), field.get("Event") or f'报告（bug_type {head.get("bug_type")}）')
    reasons = [field[k] for k in ("Writes", "CPU", "Wakeups") if k in field] + ([f'系统的处理：{field["Action taken"]}'] if "Action taken" in field else [])
    return report(path, head, kind, field.get("Hardware model"), reasons=reasons)


def summarize(reports):
    """同 DiagnosticSummary.text：同一种（类型、原因、前几帧）并成一条，计次数，最新的在前。"""
    if not reports:
        return
    groups = {}
    for r in reports:
        signature = (r["who"], r["title"], r["explanation"], r["reasons"][:1], [(f["binary"], f["offset"]) for f in r["frames"]])
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
        for reason in r["reasons"][:3]:
            print(f"原因：{reason}")
        if r["frames"]:
            print(r["frames_title"])
            for f in r["frames"]:
                place = f'{f["binary"]} +{f["offset"]:#x}' if f["offset"] is not None else f["binary"]
                print(f'  {place}' + (f'  {f["symbol"]}' if f["symbol"] else "") + ("  ← CuePad" if f["own"] else ""))
        for note in r["symbols"]:
            print(f"符号：{note}")
        print(f'文件：{"、".join(shown(g["file"]) for g in group)}')


# ---------- 日志 ----------

def usbmux(udid):
    """日志走 usbmuxd（idevicesyslog）：用线连着，或 Finder 里给这台手机开了「通过 Wi-Fi 连接时显示」；返回是不是经网络。"""
    for flag in ("-l", "-n"):
        if udid in subprocess.run(["idevice_id", flag], capture_output=True, text=True, check=True).stdout.split():
            return flag == "-n"
    sys.exit("取日志要手机经 usbmuxd 连着：用线连上这台 Mac（解锁、点信任），或在 Finder 里选中这台手机、勾上「通过 Wi-Fi 连接时显示此 iPhone」后无线也行。"
             "devicectl 的无线连接（崩溃报告走的那条）拿不到日志，原因见 device_diag.py 头注释")


def logs(follow, back):
    udid, name = device()
    network = usbmux(udid)
    target = out_dir(udid)
    now = datetime.datetime.now().replace(microsecond=0)
    start, end = now - datetime.timedelta(seconds=back), now + datetime.timedelta(seconds=follow)
    if follow:
        print(f"跟 {follow} 秒：现在在 {name} 上复现，{end:%H:%M:%S} 后取日志", flush=True)
        time.sleep(follow)
    began = time.monotonic()
    with tempfile.TemporaryDirectory(dir=target) as scratch:
        # 手机上 os_trace_relay 打包的 logarchive（与 log collect --device 同一个服务，log 那边要 root，这里不要）；tar 里直接是 logarchive 的内容
        subprocess.run(["idevicesyslog", "-u", udid, *(["-n"] if network else []), "archive", f"{scratch}/logs.tar",
                        "--start-time", str(int(start.timestamp()))], check=True)
        kept = f"{target}/last.logarchive"
        subprocess.run(["rm", "-rf", kept], check=True)
        with tarfile.open(f"{scratch}/logs.tar") as tar:
            tar.extractall(kept, filter="data")
    print(f"取日志用了 {time.monotonic() - began:.0f} 秒；完整的 logarchive：{shown(kept)}")
    out = f"{target}/logs-{start:%Y%m%d-%H%M%S}-{end:%H%M%S}.log"
    with open(out, "w") as f:
        subprocess.run(["log", "show", "--archive", kept, "--start", f"{start:%Y-%m-%d %H:%M:%S}", "--end", f"{end:%Y-%m-%d %H:%M:%S}",
                        "--info", "--debug", "--style", "compact", "--predicate", LOG_PREDICATE], stdout=f, check=True)
    lines = [l for l in open(out, encoding="utf-8", errors="replace") if re.match(r"\d{4}-\d\d-\d\d ", l)]
    by_process, by_level = {}, {}
    for line in lines:
        parts = line.split(None, 4)
        if len(parts) > 3:
            by_level[parts[2]] = by_level.get(parts[2], 0) + 1
            process = parts[3].split("[", 1)[0]
            by_process[process] = by_process.get(process, 0) + 1
    print(f"{start:%H:%M:%S}–{end:%H:%M:%S} 的日志 {len(lines)} 条 → {shown(out)}")
    print("按进程：" + ("、".join(f"{k} {v}" for k, v in sorted(by_process.items(), key=lambda kv: -kv[1])) or "无"))
    print("按级别（Df 默认、I 信息、Db 调试、E 错误、F 故障、A 活动）：" + ("、".join(f"{k} {v}" for k, v in sorted(by_level.items())) or "无"))


def main(args):
    match args:
        case ["ios", "crashes", *rest] if rest in ([], ["all"]):
            crashes(rest == ["all"])
        case ["ios", "logs", *rest] if len(rest) <= 2 and all(a.isdigit() for a in rest):
            logs(*(list(map(int, rest)) + [60, 0][len(rest):]))
        case ["ips", *paths] if paths:
            summarize([r for p in paths for r in parse(p)])
        case _:
            print(__doc__.split("\n", 1)[1].split("崩溃报告走 devicectl", 1)[0].rstrip(), file=sys.stderr)
            sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
