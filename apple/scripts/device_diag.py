#!/usr/bin/env python3
"""xc.sh diag：读各台设备上 CuePad 的诊断，只读（不装、不起停 App、不读 App 的数据、不改设置、不上传）。
用法：xc.sh diag                                      各台设备经 iCloud 送到这台 Mac 的诊断：每台几份、最新的是什么时候
      xc.sh diag <设备> [all]                          那一台的要点（崩溃、卡死、主线程卡住，同 App 里"导出诊断"），CuePad 的帧按发布归档的 dSYM 符号化；
                                                      再列它的日志（最近日志、卡住前后的日志）与路径；all 连同每份日志的全文一起打出
      xc.sh diag ios crashes [all]                     现场补充：拉连着这台 Mac 的手机上系统记下的 CuePad 崩溃报告（连同 CuePad 被内存回收的 JetsamEvent）到
                                                      apple/.derived/diag/<UDID>/、符号化、打出要点；all 连系统别的报告一起拉、一起解析
      xc.sh diag ips <文件.ips>…                         解析、符号化本机已有的系统崩溃报告（用户发来的，Mac 的 ~/Library/Logs/DiagnosticReports）
主路是 App 自己收：各台设备（iPhone、iPad、Mac）的存档（MetricKit 的诊断、本机记下的主线程卡住、手机与 iPad 的最近日志）经用户自己的 iCloud 私有库送到 Mac，
Mac 上的 CuePad 落成 <目录>/<设备>/<文件>（DiagnosticInbox.swift）。目录缺省是正式版的 ~/Library/Logs/CuePad；读隔离实例（xc.sh fleet）的给
CUEPAD_DIAG_DIR=<库目录>/Logs。<设备> 是目录名（Mac 是电脑名，iPhone、iPad 是型号代号如 iPhone18,1：iOS 不给 App 用户起的设备名），写开头几个字也行。
系统的崩溃报告走 devicectl（Xcode 自带；无线连接也行，不要 root）：systemCrashLogs 域的列出与拷出，拷出不删手机上的；手机选 CUEPAD_DIAG_DEVICE
（名字或 UDID），没给时取唯一一台配对过的真机。直连取手机的系统日志不做：devicectl 没有日志流，sysdiagnose 要管理员密码，log collect --device 要 root，
idevicesyslog 要用户在 Finder 里另开无线显示（docs/diagnose.md）。要点的格式与 App 里"导出诊断"同一套（DiagnosticSummary.swift）。"""
import json
import os
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from app_env import APPLE  # noqa: E402
from diag_report import ARCHIVES, RESOURCE_EVENTS, EXPLAIN, WATCHDOG, WATCHDOG_EVENTS, dsyms, pick, shown, summarize  # noqa: E402
from diag_inbox import inbox, overview  # noqa: E402


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

def main(args):
    match args:
        case ["ios", "crashes", *rest] if rest in ([], ["all"]):
            crashes(rest == ["all"])
        case ["ips", *paths] if paths:
            summarize([r for p in paths for r in parse(p)])
        case []:
            overview()
        case [name] | [name, "all"] if name not in ("ios", "ips", "-h", "--help"):
            inbox(name, len(args) == 2)
        case _:
            print(__doc__.split("\n", 1)[1].split("主路是 App 自己收", 1)[0].rstrip(), file=sys.stderr)
            sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
