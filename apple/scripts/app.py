#!/usr/bin/env python3
"""CuePad 的调试实例：起一份隔离实例，做一件事，一定退出。xc.sh 构建完调它，perf-mac.sh 用 exec。
用法：app.py <shot|rec|cpu|run> <mac|ios|ipad> <CuePad.app> <库目录> [--device <UDID>] [--out <图|片|秒>] [-- 启动参数…]
      app.py exec <CuePad.app> <库目录> [-- 启动参数…]   Mac 实例跑到自己退出（量完退出的 bench），标准输出原样转出
      app.py stop                                       结束本检出 run 起的 Mac 实例
      app.py preflight                                  Mac 截图、录屏前查台前调度
规则：
1. 只起 apple/.derived* 里的构建；库、偏好、各家 Agent 的配置目录、命令行链接与连接目录都在库目录或固定的 SOCKETS 下
   （isolated_env 是唯一一份，sync-bench.py 也用它），不碰真实资料库、~/.pi、~/.local/bin 与 ~/Applications/CuePad.app。
2. Mac 全机同一时间只有一份：看守进程（就是本进程）持 /tmp/cuepad-xc-<uid>/mac-app 的 flock，锁随看守进程释放，崩了也不留；
   本检出 run 起的旧实例直接换掉，别的检出的在用就排队（打印在等谁）。
3. 一定退出：做完、出错、被打断（TERM、INT、HUP）、超时（截图类 HOLD 秒，run 是 RUN_TTL）都走 quit：先 TERM 走 App 的正常退出，
   5 秒不退再 KILL，连同它起的子进程（Cue 的 pi、cuepad mcp）一起结束。
4. 不靠固定等待：Debug 构建摆好画面后写就绪文件（CUEPAD_SHOT_READY，DebugScene.signalReady），这里用 kqueue 等它出现或 App 退出。
   给了 CUEPAD_SHOT_READY 的 Mac 实例在后台跑、不进 Dock、不抢前台（DebugHooks.staysInBackground）。
5. Mac 截图、录屏按窗口拍（wincap.swift，尺寸对不上就失败）；启动参数没给窗口尺寸时用 WINDOW。
6. cpu（xc.sh 给 Release 构建）：画面就绪后静置 SETTLE 秒，量 N 秒内进程自己的 CPU 时间、指令数、唤醒与内存（proc_pid_rusage），
   每次全新进程，跑 RUNS 次取中位。这几项不随机器忙闲变：前后对比就是两个检出各跑同一条命令。
iOS、iPadOS：模拟器里本就隔离，同一台上再 launch 就换掉旧的；状态栏固定成 9:41、满格满电，做完 terminate，run 留着。
"""
import ctypes
import fcntl
import json
import os
import re
import select
import signal
import statistics
import subprocess
import sys
import time

APPLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKOUT = os.path.dirname(APPLE)
BUNDLE_ID = "com.sugeh.cuepad"
RUNTIME = f"/tmp/cuepad-xc-{os.getuid()}"  # 与 _lock.sh 同一处
SLOT = f"{RUNTIME}/mac-app"
SOCKETS = f"/tmp/cuepad-app-{os.getuid()}"  # 终端里的会话要连这个实例就 export CUEPAD_PI_SOCKET_DIR 为它；sun_path 限 104 字节
BUILD = re.compile(r".*/apple/\.derived[^/]*/Build/Products/[^/]+/CuePad\.app")
WINDOW = "1440x900"
READY_TIMEOUT = 60
HOLD = 300  # 截图类的看守上限（另加录屏、测量的秒数）：卡在哪一步都不留实例
RUN_TTL = 15 * 60  # 够一轮 bcu 交互验收；忘了收的实例曾活过 14 小时
SETTLE, RUNS, CPU_SECONDS = 2, 3, 10
REC_SECONDS = float(os.environ.get("CUEPAD_REC_SECONDS", 12))


def die(message):
    print(message, file=sys.stderr, flush=True)
    sys.exit(1)


def isolated_env(library, sockets=SOCKETS):
    agents = f"{library}/agents"
    return dict(os.environ, CUEPAD_LIBRARY_DIR=library, CUEPAD_BIN_DIR=f"{library}/bin", CUEPAD_PI_SOCKET_DIR=sockets,
                PI_CODING_AGENT_DIR=f"{agents}/pi", CLAUDE_CONFIG_DIR=f"{agents}/claude",
                CODEX_HOME=f"{agents}/codex", OPENCODE_CONFIG_DIR=f"{agents}/opencode")


def interrupted(sig, _):
    if sig == signal.SIGALRM:
        print("看守超时，结束实例", file=sys.stderr, flush=True)
    raise SystemExit(128 + sig)


# ---------- 进程 ----------

def descendants(pid):
    children = {}
    for line in subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.splitlines():
        p, parent = map(int, line.split())
        children.setdefault(parent, []).append(p)
    found, todo = [], list(children.get(pid, []))
    while todo:
        p = todo.pop()
        found.append(p)
        todo += children.get(p, [])
    return found


def quit_mac(proc):
    if proc.poll() is not None:
        return
    rest = descendants(proc.pid)  # App 退出后它们就挂到 launchd 下了，先记下
    proc.terminate()
    try:
        proc.wait(5)
    except subprocess.TimeoutExpired:
        print(f"实例 {proc.pid} 5 秒没退出，强制结束", file=sys.stderr, flush=True)
        proc.kill()
        proc.wait()
    for p in rest:
        try:
            os.kill(p, signal.SIGTERM)
        except ProcessLookupError:
            pass


def wait_ready(path, pid, log):
    """等就绪文件出现；App 先退出（多半是崩了）或超时就失败。"""
    queue, folder = select.kqueue(), os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        watch = [select.kevent(folder, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR, select.KQ_NOTE_WRITE),
                 select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)]
        try:
            queue.control(watch, 0)
            exited = False
        except ProcessLookupError:
            exited = True
        deadline = time.monotonic() + READY_TIMEOUT
        while not os.path.exists(path):
            if exited:
                die(f"App 在画面就绪前退出了：崩溃报告在 ~/Library/Logs/DiagnosticReports/CuePad-*.ips，输出在 {log}")
            left = deadline - time.monotonic()
            if left <= 0:
                die(f"{READY_TIMEOUT} 秒内画面没有就绪（没有写下 {path}），输出在 {log}")
            exited = any(e.filter == select.KQ_FILTER_PROC for e in queue.control(None, 2, left))
    finally:
        os.close(folder)
        queue.close()
    with open(path) as f:
        return f.read().split()


# ---------- 测量 ----------

class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "user", "system", "idle_wakeups", "interrupt_wakeups", "pageins", "wired", "resident", "footprint",
        "start", "exit", "child_user", "child_system", "child_idle_wakeups", "child_interrupt_wakeups", "child_pageins",
        "child_elapsed", "disk_read", "disk_written", "qos_default", "qos_maintenance", "qos_background", "qos_utility",
        "qos_legacy", "qos_user_initiated", "qos_user_interactive", "billed_system", "serviced_system", "logical_writes",
        "lifetime_max_footprint", "instructions", "cycles")]


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


libc = ctypes.CDLL("/usr/lib/libSystem.dylib")
timebase = Timebase()
libc.mach_timebase_info(ctypes.byref(timebase))


def usage(pid):
    u = Usage()
    if libc.proc_pid_rusage(pid, 4, ctypes.byref(u)) != 0:  # RUSAGE_INFO_V4
        die(f"读不到 {pid} 的资源用量（进程退出了？）")
    return u


def measure(pid, seconds):
    time.sleep(SETTLE)
    a, start = usage(pid), time.monotonic()
    time.sleep(seconds)  # 量的就是这一段
    b, wall = usage(pid), time.monotonic() - start
    cpu_ms = (b.user + b.system - a.user - a.system) * timebase.numer / timebase.denom / 1e6
    return {"CPU %": cpu_ms / wall / 10, "CPU ms": cpu_ms, "指令 M": (b.instructions - a.instructions) / 1e6,
            "唤醒/秒": (b.idle_wakeups + b.interrupt_wakeups - a.idle_wakeups - a.interrupt_wakeups) / wall,
            "内存 MB": b.footprint / 2**20}


def report(rows, seconds):
    def line(label, row):
        return f"{label}  " + "  ".join(f"{k} {v:.1f}" for k, v in row.items())
    for i, row in enumerate(rows, 1):
        print(line(f"第 {i} 次", row), flush=True)
    median = {k: statistics.median(r[k] for r in rows) for k in rows[0]}
    print(line(f"中位（{len(rows)} 次，每次就绪后 {SETTLE}+{seconds:g} 秒，负载 {os.getloadavg()[0]:.0f}）", median))


# ---------- Mac ----------

def holder_alive(note):
    pid = note.get("holder")
    command = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout if pid else ""
    return "app.py" in command


def read_note(slot):
    slot.seek(0)
    try:
        return json.loads(slot.read() or "{}")
    except ValueError:
        return {}


def take_slot():
    os.makedirs(RUNTIME, exist_ok=True)
    slot = open(SLOT, "a+")
    try:
        fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return slot
    except BlockingIOError:
        pass
    note = read_note(slot)
    if note.get("checkout") == CHECKOUT and holder_alive(note):
        os.kill(note["holder"], signal.SIGTERM)  # 本检出 run 起的旧实例：换掉
    else:
        print(f"排队：Mac 调试实例在用（全机只开一份）\n  {note.get('what', '?')}  {note.get('checkout', '?')}  {note.get('since', '')} 起",
              file=sys.stderr, flush=True)
    fcntl.flock(slot, fcntl.LOCK_EX)
    return slot


class Mac:
    """持着全机那一份的看守：start 起实例，quit 收掉（with 块结束时一定收）。"""

    def __init__(self, app, library, what, ready=True):
        if not BUILD.fullmatch(app):
            die(f"只起 apple/.derived* 里的构建，不起 {app}")
        self.app, self.library, self.what, self.proc = app, os.path.abspath(library), what, None
        self.ready = f"{RUNTIME}/mac-ready" if ready else None
        self.log = re.sub(r"/Build/Products/.*", "/app-mac.log", app)

    def __enter__(self):
        self.slot = take_slot()
        return self

    def start(self, args):
        if "-CuePadWindowSize" not in args:
            args = [*args, "-CuePadWindowSize", WINDOW]
        os.makedirs(SOCKETS, mode=0o700, exist_ok=True)
        env = isolated_env(self.library)
        if self.ready:
            env["CUEPAD_SHOT_READY"] = self.ready
            if os.path.exists(self.ready):
                os.remove(self.ready)
        out = open(self.log, "w") if self.ready else None
        self.proc = subprocess.Popen([f"{self.app}/Contents/MacOS/CuePad", *args], env=env, stdin=subprocess.DEVNULL,
                                     stdout=out, stderr=subprocess.STDOUT if out else None)
        self.slot.truncate(0)
        self.slot.write(json.dumps({"holder": os.getpid(), "app": self.proc.pid, "checkout": CHECKOUT, "what": self.what,
                                    "since": time.strftime("%H:%M:%S")}, ensure_ascii=False))
        self.slot.flush()
        return wait_ready(self.ready, self.proc.pid, self.log) if self.ready else None

    def quit(self):
        if self.proc:
            quit_mac(self.proc)

    def __exit__(self, *_):
        self.quit()
        self.slot.truncate(0)
        self.slot.close()


def wincap():
    source, binary = f"{APPLE}/scripts/wincap.swift", f"{APPLE}/.derived/wincap"
    if not os.path.exists(binary) or os.path.getmtime(source) > os.path.getmtime(binary):
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        subprocess.run(["swiftc", "-O", source, "-o", binary], check=True)
    return binary


def mac(cmd, app, library, out, args):
    if cmd == "run":
        return run_mac(app, library, args)
    signal.alarm(HOLD + int(float(out or 0) * RUNS if cmd == "cpu" else REC_SECONDS if cmd == "rec" else 0))
    with Mac(app, library, cmd) as m:
        if cmd == "cpu":
            rows = []
            for _ in range(RUNS):
                m.start(args)
                rows.append(measure(m.proc.pid, float(out)))
                m.quit()
            return report(rows, float(out))
        size = m.start(args)
        if len(size) != 2:
            die("就绪文件里没有窗口尺寸：画面没有可拍的普通窗口")
        capture = ["rec", str(m.proc.pid), str(REC_SECONDS)] if cmd == "rec" else ["shot", str(m.proc.pid)]
        os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
        subprocess.run([wincap(), *capture, *size, out], check=True)


def run_mac(app, library, args):
    """起着给 bcu 操作：看守进程脱离 xc.sh 在后台守到 App 退出、RUN_TTL 或 stop，这里等就绪后打印 PID 就返回。"""
    report_r, report_w = os.pipe()
    if os.fork():
        os.close(report_w)
        pid = os.read(report_r, 32).decode()
        if not pid:
            sys.exit(1)
        print(pid)
        return
    os.close(report_r)
    os.setsid()
    signal.alarm(RUN_TTL)
    with Mac(app, library, "run") as m:
        m.start(args)
        os.write(report_w, str(m.proc.pid).encode())
        os.close(report_w)
        # 不再占着调用方的输出：否则调用方要等这个后台进程结束才拿到结果
        null = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(null, fd)
        m.proc.wait()


def exec_mac(app, library, args):
    with Mac(app, library, "exec", ready=False) as m:
        m.start(args)
        sys.exit(m.proc.wait())


def stop():
    os.makedirs(RUNTIME, exist_ok=True)
    with open(SLOT, "a+") as slot:
        note = read_note(slot)
        if note.get("checkout") != CHECKOUT or not holder_alive(note):
            print("本检出没有在跑的 Mac 实例")
            return
        os.kill(note["holder"], signal.SIGTERM)
        fcntl.flock(slot, fcntl.LOCK_EX)  # 看守收完实例才放锁
    print(f"已结束 {note['app']}")


def preflight():
    stage = subprocess.run(["defaults", "read", "com.apple.WindowManager", "GloballyEnabled"], capture_output=True, text=True).stdout
    if stage.strip() == "1":
        die("台前调度开着：后台窗口被缩小显示，截图、录屏的尺寸不对。请用户在控制中心关掉台前调度再拍")


# ---------- 模拟器 ----------

def simctl(*args, **kw):
    return subprocess.run(["xcrun", "simctl", *args], check=True, **kw)


def launch_sim(device, library, args, ready):
    if os.path.exists(ready):
        os.remove(ready)
    env = dict(os.environ, SIMCTL_CHILD_CUEPAD_LIBRARY_DIR=os.path.abspath(library), SIMCTL_CHILD_CUEPAD_SHOT_READY=ready)
    out = simctl("launch", "--terminate-running-process", device, BUNDLE_ID, *args, env=env, capture_output=True, text=True).stdout
    return int(out.rsplit(":", 1)[1])


def recorder(device, out):
    """开始录屏，等它说开录了再返回（开录前约半秒没有帧）。recordVideo 收到 SIGINT 才把文件写完整。"""
    proc = subprocess.Popen(["xcrun", "simctl", "io", device, "recordVideo", "--codec", "h264", "--force", out],
                            stderr=subprocess.PIPE, text=True)
    for line in proc.stderr:
        if "Recording started" in line:
            return proc
    die("模拟器录屏没有开始")


def stop_recording(proc):
    time.sleep(REC_SECONDS)  # 录多久是要录的内容
    proc.send_signal(signal.SIGINT)
    proc.wait()


def sim(cmd, device, app, library, out, args):
    ready, log = f"{RUNTIME}/ready-{device}", "模拟器里（xcrun simctl spawn <UDID> log show）"
    simctl("install", device, app)
    simctl("status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
           "--cellularMode", "active", "--cellularBars", "4", "--wifiBars", "3")
    signal.alarm(HOLD + int(float(out or 0) * RUNS if cmd == "cpu" else REC_SECONDS if cmd == "rec" else 0))
    try:
        if cmd == "cpu":
            rows = []
            for _ in range(RUNS):
                pid = launch_sim(device, library, args, ready)
                wait_ready(ready, pid, log)
                rows.append(measure(pid, float(out)))
            return report(rows, float(out))
        if cmd == "rec" and os.environ.get("CUEPAD_REC_LAUNCH"):
            rec = recorder(device, out)  # 冷启动：先开录再起 App，录满秒数、不等就绪
            launch_sim(device, library, args, ready)
            stop_recording(rec)
        else:
            pid = launch_sim(device, library, args, ready)
            wait_ready(ready, pid, log)
            if cmd == "run":
                print(pid, device)
                return
            if cmd == "rec":
                stop_recording(recorder(device, out))
            else:
                simctl("io", device, "screenshot", out, capture_output=True)
        print(out)
    finally:
        if cmd != "run":
            subprocess.run(["xcrun", "simctl", "terminate", device, BUNDLE_ID], capture_output=True)


def main(argv):
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGALRM):
        signal.signal(s, interrupted)
    launch_args = argv[argv.index("--") + 1:] if "--" in argv else []
    argv = argv[:argv.index("--")] if "--" in argv else argv
    cmd = argv[0] if argv else ""
    if cmd == "stop":
        return stop()
    if cmd == "preflight":
        return preflight()
    if cmd == "exec":
        return exec_mac(argv[1], argv[2], launch_args)
    if cmd not in ("shot", "rec", "cpu", "run") or len(argv) < 4:
        die(__doc__)
    platform, app, library = argv[1:4]
    options = dict(zip(argv[4::2], argv[5::2]))
    derived = re.sub(r"/Build/Products/.*", "", app)
    out = options.get("--out") or {"shot": f"{derived}/shot-{platform}.png", "rec": f"{derived}/rec-{platform}.mov",
                                   "cpu": str(CPU_SECONDS)}.get(cmd)
    if platform == "mac":
        return mac(cmd, app, library, out, launch_args)
    sim(cmd, options["--device"], app, library, out, launch_args)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main(sys.argv[1:])
