#!/usr/bin/env python3
"""xc.sh perf 的测量：xc.sh 构建好 Release（带 DEBUG 条件，只为留下测量代码与调试场景；产物在 apple/.derived-perf，Instruments 也用这份）、
进了锁（iOS 另领好模拟器槽位，每次从刚开机的模拟器量：开着很久的模拟器上同一交互的指令数能高出一倍）之后调它。
用法：perf.py interact <mac|ios> <CuePad.app> [次数=3] [启动参数…]
      perf.py idle <mac|ios> <CuePad.app> [次数=3] [秒=30] [启动参数…]
      perf.py launch mac <CuePad.app> [次数=5] [启动参数…]
iOS 的模拟器是 CUEPAD_PERF_DEVICE（xc.sh 给）。启动参数原样传给 App。每次都是全新进程与一份没量过的库（量的动作会写库）。
不独占机器：别的编译、测试同时跑时指令数之外的数会被拖歪，xc.sh 结束的用时行带 1 分钟负载（高于核数就只比指令数）。
每次的原始行写进 apple/.derived-perf/Build 的 interact.jsonl、idle.jsonl、launch.jsonl（开跑时清空重写，perf-ab.py 读它们），最后打中位数的表。
共用：
  CUEPAD_PERF_SEED=<库目录>（如真实库的只读副本，先用这个构建打开一次，免得量进升级库结构）：每次从它克隆，换掉演示库与大库。
  CUEPAD_TRACE=<xctrace 模板>（如 'Animation Hitches'、'Time Profiler'）：每次量的同时录 trace，存 apple/.derived-perf/Build/traces/；
    Mac 按 PID 录：App 带 -CuePadTraceWait YES 起，写 AWAIT trace <PID> 停着等（Probes.swift 的 waitForTracer），开录后发 SIGUSR1 放它走；
    模拟器里的进程 xctrace 按 PID、按名字都认不出，iOS 录整机，按打印的 PID 筛。录着的那几次时刻不和不录的比。

interact（-CuePadBench interact）单次交互：逐项量点击回合（动作发出到画面第一次变的主线程 CPU 毫秒）与其中的指令数、每毫秒跑的周期
  （GHz：活一样多而回合翻倍时它减半，是机器那一刻慢）、合计、最重一圈、指令数与掉帧，取各次的中位数列成表。
  -CuePadInteractOnly 项,项 只量列出的几项（列的项之间要自己够得着，如开编辑页配收编辑页）。
  Mac：演示库与大库（-CuePadSeed perf：50 项目、5000 卡、300 张大图、200 个 Pi 历史会话，前 12 个带长对话，写一次留在 library-perf）各量一遍；
    给了 CUEPAD_PERF_SEED 时只量那份库，配 -CuePadProject <库里的项目名>。宽屏自动阈值那几项另列一张（静置时主线程与进程的指令、反向时的滑动），
    没跨过阈值、画面没变、栏宽或保留的状态与页面不对时不论前后台都以 1 退出；页面的阅读位置验不了的栏在演示库上标「页面验不了」，在大库上判失败
    （大库就是为验这一条）。默认在后台量：指令数照样前后对比，帧与掉帧偏乐观，不和预算比；加 -CuePadForeground YES 在前台量（apple/scripts/AGENTS.md「占前台」），
    有一项超了预算就以 1 退出。前台量时"任务气泡开"是真实点击：App 写 AWAIT click x y，这里用 hid.swift 经 HID 点那一行（会移动真实指针，量完放回）。
  iOS（IOSInteractionBench）：演示库，按"第几次"分开取中位数；"落点"是量完时的根与推入的页。模拟器的合成与 GPU 和真机不同：只看主线程 CPU 与指令数，
    掉帧只作参考。长按菜单与手势在进程内没有入口：App 写 AWAIT 名 x y（按）或 AWAIT 名 x y x2 y2 swipe|drag 秒，这里用 axe 真按（长按菜单按住 0.8 秒）、
    真滑、真拖（每秒 60 个移动点）。每次最多等 CUEPAD_INTERACT_SECONDS 秒（默认 300），某一次没写完整次失败、以 1 退出，不出部分结果的表。
idle：空闲与常驻开销。等就绪后至少静置 CUEPAD_IDLE_SETTLE 秒（默认 5，iOS 演示库首启那条"做完了"的提示 5 秒后收起），再等启动后的收尾做完，
  量接下来 <秒> 内的唤醒、指令、CPU、能耗与内存（口径见 rusage.py），各次取中位数。等不到安静整次失败；CUEPAD_IDLE_ALLOW_NOISY=1 放行照量，表尾标出。
  CUEPAD_IDLE_BACKGROUND=1（仅 ios）：就绪后切到设置 App，量 CuePad 进后台之后的开销。
launch：冷启动到首屏。从种子克隆的库（没给 CUEPAD_PERF_SEED 时先写一份演示库留在 library-launch-seed，之后不带演示参数），打开库里记着的那一页；
  量 exec 成 CuePad 起到进 main、主窗口上屏、首屏内容出来、能交互的墙钟毫秒，与到那一刻主线程、整个进程的指令（百万）和主线程 CPU 毫秒（LaunchBench.swift）。
  墙钟随机器忙闲变，每行带当时的 1 分钟负载；前后对比用 xc.sh perf ab，以主线程的指令数为准。
"""
import json
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
import rusage  # noqa: E402
from _perf import SEED, TRACE, fail, fresh, mac, medians, relay, rows_file, seeded, stop, trace_path  # noqa: E402
from app_env import SLOT  # noqa: E402
from app_sim import Sim  # noqa: E402
from perf_interact import interact_ios, interact_mac  # noqa: E402


def idle(app, derived, platform, runs, seconds, extra, sim):
    settle = float(os.environ.get("CUEPAD_IDLE_SETTLE", 5))
    library, ready = f"{derived}/library-idle", f"{derived}/idle-ready"
    rows = []
    for run in range(1, runs + 1):
        fresh(library, SEED)
        if os.path.exists(ready):
            os.remove(ready)
        args = [*([] if SEED else ["-CuePadDemo", "YES"]), *extra]
        on_ready = None
        # 渲染服务（rusage.py 的 render*）：Mac 是 WindowServer，iOS 是这台模拟器的 launchd_sim（参数里带 UDID）下的 backboardd
        if platform == "mac":
            proc = mac(app, library, args, ready)
            pid, quit = proc.pid, lambda: stop(proc)
            render = pgrep("-x", "WindowServer")
        else:
            pid, quit = sim.launch(library, args, ready), sim.terminate
            render = pgrep("-P", pgrep("-f", f"launchd_sim .*{sim.device}"), "backboardd")
            if os.environ.get("CUEPAD_IDLE_BACKGROUND"):
                on_ready = ["xcrun", "simctl", "launch", sim.device, "com.apple.Preferences"]
        during = None
        if TRACE:
            trace = trace_path(derived, f"idle-{platform}-{run}")
            target = ["--attach", str(pid)] if platform == "mac" else ["--device", sim.device, "--all-processes"]
            during = ["xcrun", "xctrace", "record", "--template", TRACE, *target, "--time-limit", f"{seconds:g}s", "--output", trace]
            print(f"trace：CuePad PID {pid}", file=sys.stderr)
        try:
            rows.append(rusage.measure(pid, ready, settle, seconds, render, on_ready=on_ready, during=during))
        finally:
            quit()
        print(json.dumps(rows[-1]), flush=True)
    shutil.rmtree(library, ignore_errors=True)
    rows_file(derived, "idle", rows)
    medians(rows, [k for k in rows[0] if k != "quiet"])
    noisy = [n for n, r in enumerate(rows, 1) if not r["quiet"]]
    if noisy:
        print(f"不可信：第 {noisy} 次没等到安静（CUEPAD_IDLE_ALLOW_NOISY=1 放行的），含启动收尾或别的负载，不能当静置基线")


def pgrep(*args):
    return int(subprocess.run(["pgrep", *map(str, args)], capture_output=True, text=True, check=True).stdout.split()[0])


def launch(app, derived, runs, extra):
    seed = SEED or seeded(f"{derived}/library-launch-seed", app, ["-CuePadDemo", "YES"], 120, "演示库")
    library, rows = f"{derived}/library-launch", []
    moments = ("entry", "window", "content", "interactive")
    for run in range(1, runs + 1):
        fresh(library, seed)
        trace = trace_path(derived, f"launch-{run}") if TRACE else None
        proc = mac(app, library, ["-CuePadBench", "launch", *(["-CuePadTraceWait", "YES"] if TRACE else []), *extra], stdout=subprocess.PIPE)
        status, lines = relay(proc, trace)
        line = next((l for l in lines if l.startswith("LAUNCH ")), None)
        if line is None or status:
            fail(f"CuePad 没量完（退出码 {status}）：{''.join(lines)[-500:]}")
        # 时刻减去 exec 成 CuePad 的那一刻（app.py exec 记在本检出的锁记录里，rusage.py 同口径）
        raw, exec_at = json.loads(line[7:]), json.load(open(SLOT))["execAt"]
        ms = lambda t: round((t - exec_at) / 1e6)
        row = {k: ms(raw[k]) for k in moments} | {k: raw[k] for k in raw if k.endswith(("MainM", "AllM", "CPUMs"))}
        row |= {"long": [[ms(a), round((b - a) / 1e6)] for a, b in raw["long"]], "load": round(os.getloadavg()[0])}
        print(json.dumps(row, ensure_ascii=False), flush=True)
        rows.append(row)
    shutil.rmtree(library, ignore_errors=True)
    rows_file(derived, "launch", rows)
    medians(rows, [*moments, *(m + metric for metric in ("MainM", "AllM", "CPUMs") for m in moments), "load"])


def main(argv):
    if len(argv) < 3 or tuple(argv[:2]) not in {("interact", "mac"), ("interact", "ios"), ("idle", "mac"), ("idle", "ios"), ("launch", "mac")}:
        fail(__doc__, 2)
    kind, platform, app, *rest = argv
    derived = os.path.dirname(os.path.dirname(os.path.dirname(app)))
    sim = None
    if platform == "ios":
        sim = Sim(os.environ["CUEPAD_PERF_DEVICE"], f"{derived}/app-sim.log")
        sim.run("install", sim.device, app)
    count = lambda default: int(rest[0]) if rest else default
    if kind == "interact" and platform == "mac":
        interact_mac(app, derived, count(3), rest[1:])
    elif kind == "interact":
        interact_ios(app, derived, count(3), rest[1:], sim)
    elif kind == "idle":
        idle(app, derived, platform, count(3), float(rest[1]) if len(rest) > 1 else 30, rest[2:], sim)
    else:
        launch(app, derived, count(5), rest[1:])


if __name__ == "__main__":
    main(sys.argv[1:])
