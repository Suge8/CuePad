"""perf.py interact：单次交互（用法与口径见 perf.py 头注释）。"""
import json
import os
import shutil
import signal
import statistics as st
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from _perf import SEED, TRACE, fail, fresh, mac, relay, rows_file, seeded, trace_path  # noqa: E402
from app_env import APPLE, BUNDLE_ID  # noqa: E402


def interact_mac(app, derived, runs, extra):
    click, source = f"{derived}/hid", f"{APPLE}/scripts/hid.swift"
    if not os.path.exists(click) or os.path.getmtime(source) > os.path.getmtime(click):
        subprocess.run(["xcrun", "swiftc", "-O", source, "-o", click], check=True)
    if SEED:
        libraries = [("真实库", SEED, [])]
    else:
        big = seeded(f"{derived}/library-perf", app, ["-CuePadSeed", "perf", "-CuePadProject", "大项目"], 900, "大库")
        libraries = [("演示库", None, ["-CuePadDemo", "YES", "-CuePadProject", "圆桌"]), ("大库", big, ["-CuePadProject", "大项目"])]
    rows = []
    for label, source, args in libraries:
        for run in range(1, runs + 1):
            library = f"{derived}/library-run"
            fresh(library, source)
            trace = trace_path(derived, f"interact-{label}-{run}") if TRACE else None
            proc = mac(app, library, [*args, "-CuePadBench", "interact", "-CuePadWindowSize", "1440x900",
                                      *(["-CuePadTraceWait", "YES"] if TRACE else []), *extra], stdout=subprocess.PIPE)
            status, lines = relay(proc, trace, click)
            if status:
                for line in lines:
                    if line.startswith("BENCH-ERR "):
                        print(f"CuePad 没量完（{label}）：{line[10:].strip()}", file=sys.stderr)
                sys.exit(status)
            rows += [{"库": label, **json.loads(line[9:])} for line in lines if line.startswith("INTERACT ")]
    shutil.rmtree(f"{derived}/library-run", ignore_errors=True)
    rows_file(derived, "interact", rows)
    sys.exit(mac_table(rows))


def mac_table(rows):
    order = list(dict.fromkeys((r["库"], r["name"]) for r in rows))
    foreground = all(r.get("foreground") for r in rows)
    over = 0
    if not foreground:
        print("后台量的：帧与掉帧偏乐观，不和预算比（加 -CuePadForeground YES 在前台量才比）")
    print(f"{'库':6}{'交互':14}{'点击回合 ms':>12}{'预算':>7}{'其中指令 M':>10}{'GHz':>6}{'合计 ms':>9}{'指令 M':>8}{'最重一圈':>9}{'掉帧':>6}{'预算':>6}{'最长帧 ms':>10}  结果")
    for key in order:
        samples = [r for r in rows if (r["库"], r["name"]) == key]
        m = lambda f: st.median(r[f] for r in samples)
        click, hitches = m("clickMs"), m("hitches")
        budget_click, budget_hitches = samples[0]["budgetClickMs"], samples[0]["budgetHitches"]
        ok = click <= budget_click and hitches <= budget_hitches
        over += foreground and not ok
        unseen = "，未见变化" if not all(r["seen"] for r in samples) else ""
        print(f"{key[0]:6}{key[1]:14}{click:12.1f}{budget_click:7.0f}{m('clickInstructionsM'):10.0f}{m('clickGHz'):6.2f}{m('totalMs'):9.0f}{m('instructionsM'):8.0f}"
              f"{m('maxTurnMs'):9.1f}{hitches:6.0f}{budget_hitches:6d}{max(r['worstMs'] for r in samples):10.1f}  {('ok' if ok else '超预算') if foreground else '-'}{unseen}")
    # 宽屏自动阈值的几项另有正确性（InteractionBench+Wide.swift）；大库的列与对话都长到能滚，那里页面验不了不算通过，演示库上只标出来
    wide = [r for r in rows if "railOK" in r]
    page_ok = lambda r: r["page"] == "ok" if r["库"] == "大库" else r["page"] != "broken"
    broken = [r for r in wide if not (r["crossed"] and r["seen"] and r["railOK"] and r["stateOK"] and page_ok(r))]
    if wide:
        print(f"\n{'库':6}{'宽屏':18}{'静置主线程 M':>12}{'静置进程 M':>11}{'每帧位移':>9}{'漏采帧':>7}{'停下差':>7}  状态")
        for key in order:
            samples = [r for r in wide if (r["库"], r["name"]) == key]
            if not samples:
                continue
            slide = [r for r in samples if "perFramePt" in r]
            motion = (f"{max(r['perFramePt'] for r in slide):9.1f}{max(r['gapFrames'] for r in slide):7.0f}{max(abs(r['restPt']) for r in slide):7.1f}"
                      if slide else f"{'-':>9}{'-':>7}{'-':>7}")
            bad = [k for k in ("crossed", "seen", "railOK", "stateOK") if not all(r[k] for r in samples)] + (["page"] if any(not page_ok(r) for r in samples) else [])
            untested = sorted({c for r in samples for c in r["pageUntested"]})
            status = "不符：" + ",".join(bad) if bad else f"页面验不了：{','.join(untested)}" if untested else "ok"
            print(f"{key[0]:6}{key[1]:18}{st.median(r['idleMainM'] for r in samples):12.1f}{st.median(r['idleProcessM'] for r in samples):11.1f}{motion}  {status}")
    return 1 if over or broken else 0


def interact_ios(app, derived, runs, extra, sim):
    limit = float(os.environ.get("CUEPAD_INTERACT_SECONDS", 300))
    rows = []
    for run in range(1, runs + 1):
        library = f"{derived}/library-{run}"
        fresh(library, SEED)
        out = f"{library}/interact.jsonl"
        lines = lambda: open(out).read().splitlines() if os.path.exists(out) else []
        trace = trace_path(derived, f"interact-ios-{run}") if TRACE else None
        tracer = xctrace_device(sim.device, trace) if TRACE else None
        pid = sim.launch(library, [*([] if SEED else ["-CuePadDemo", "YES"]), "-CuePadBench", "interact", "-CuePadSearchScope", "sessions", *extra], f"{library}.ready")
        if TRACE:
            print(f"trace：CuePad PID {pid}", file=sys.stderr)
        pressed, finished, asked = 0, False, 0.0
        began = told = time.monotonic()
        awaits = []
        while time.monotonic() - began < limit:
            awaits = [l.split()[1:] for l in lines() if l.startswith("AWAIT ")]
            if len(awaits) > pressed:
                touch(sim.device, *awaits[pressed])
                pressed += 1
                continue
            now = time.monotonic()
            # 问模拟器"还在跑吗"要几百毫秒：每秒问一次，按点的请求每 0.1 秒看一次
            if now - asked >= 1:
                asked = now
                if not running(sim.device):
                    finished = True
                    break
            if now - told >= 30:
                told = now
                print(f"第 {run} 次：已等 {now - began:.0f} 秒（最多 {limit:g} 秒），App 要按 {len(awaits)} 个点、已按 {pressed} 个", file=sys.stderr)
            time.sleep(0.1)
        if tracer:
            stop_xctrace(tracer, trace)
        last = (lines() or [""])[-1]
        if not finished:
            sim.terminate()
            fail(f"第 {run} 次：{limit:g} 秒内没量完（App 要按 {len(awaits)} 个点、已按 {pressed} 个）；输出最后一行：{last}\n"
                 f"下一步：看 {out} 的末尾判断卡在哪一项；机器忙或项目多就给 CUEPAD_INTERACT_SECONDS=<秒> 放宽")
        failed = [l for l in lines() if l.startswith("FAIL ")]
        if failed or "DONE" not in lines():
            fail(f"第 {run} 次没量完：{failed[0] if failed else 'App 中途退出'}")
        rows += [{"run": run, **json.loads(l[9:])} for l in lines() if l.startswith("INTERACT ")]
    rows_file(derived, "interact", rows)
    groups, seen = {}, {}
    for r in rows:
        seen[(r["run"], r["name"])] = seen.get((r["run"], r["name"]), 0) + 1
        groups.setdefault((r["name"], seen[(r["run"], r["name"])]), []).append(r)
    print("交互\t第几次\t点击回合ms\t其中指令百万\tGHz\t合计ms\t最重一圈ms\t指令百万\t掉帧\t内存MB\t启动到对话ms\t落点")
    for (name, nth), samples in groups.items():
        m = lambda f: st.median(r[f] for r in samples)
        print(f"{name}\t{nth}\t{m('clickMs'):.1f}\t{m('clickInstructionsM'):.0f}\t{m('clickGHz'):.2f}\t{m('totalMs'):.1f}\t{m('maxTurnMs'):.1f}\t{m('instructionsM'):.0f}"
              f"\t{m('hitches'):.0f}\t{m('footprintMB'):.1f}\t{m('launchMs') if 'launchMs' in samples[0] else ''}\t{' / '.join(dict.fromkeys(r.get('landed', '') for r in samples))}")


def touch(device, name, x, y, *rest):
    axe = lambda *a: subprocess.run(["axe", *map(str, a), "--udid", device], check=True, stdout=subprocess.DEVNULL)
    x2, y2, how, seconds = rest if rest else (None, None, None, None)
    if how == "drag":
        axe("drag", "--start-x", x, "--start-y", y, "--end-x", x2, "--end-y", y2, "--duration", seconds, "--steps", round(float(seconds) * 60))
    elif how == "swipe":
        axe("swipe", "--start-x", x, "--start-y", y, "--end-x", x2, "--end-y", y2, "--duration", seconds, "--delta", 10)
    elif name == "长按菜单":
        axe("touch", "-x", x, "-y", y, "--down")
        time.sleep(0.8)
        axe("touch", "-x", x, "-y", y, "--up")
    else:
        axe("tap", "-x", x, "-y", y)


def running(device):
    listing = subprocess.run(["xcrun", "simctl", "spawn", device, "launchctl", "list"], capture_output=True, text=True).stdout
    return f"UIKitApplication:{BUNDLE_ID}" in listing


def xctrace_device(device, trace):
    """录整台模拟器（开录了再返回，冷启动才录得到）；xctrace 连设备卡住（60 秒不出 Starting recording）就放弃、以 1 退出。"""
    log = open(f"{trace}.log", "w")
    proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", TRACE, "--device", device, "--all-processes", "--output", trace],
                            stdout=log, stderr=subprocess.STDOUT)
    for _ in range(600):
        if "Starting recording" in open(f"{trace}.log").read():
            return proc
        time.sleep(0.1)
    proc.kill()
    fail(f"xctrace 60 秒没开录（多半卡在连设备上，见 {trace}.log）")


def stop_xctrace(proc, trace):
    proc.send_signal(signal.SIGINT)
    try:
        proc.wait(60)
    except subprocess.TimeoutExpired:
        proc.kill()
        fail(f"xctrace 收到 Ctrl-C 60 秒没写完，{trace} 不完整")
