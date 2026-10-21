#!/usr/bin/env python3
"""CuePad 的调试实例：起一份隔离实例，做一件事，一定退出。xc.sh 构建完调它，perf-mac.sh 用 exec。
用法：app.py <shot|rec|run> <mac|ios|ipad> <CuePad.app> <库目录> [--device <UDID>] [--out <图|片>] [-- 启动参数…]
      app.py exec <CuePad.app> <库目录> [-- 启动参数…]   占住本检出那一份后 exec 成 CuePad（量完自己退出的 bench 用，$! 就是 CuePad）
      app.py stop                                       结束本检出 run 起的 Mac 实例
      app.py sockets                                    本检出实例的连接目录（终端里的会话 export CUEPAD_PI_SOCKET_DIR 为它才连得上）
      app.py preflight                                  Mac 截图、录屏前查台前调度
另有 wait_ready（kqueue 等就绪文件）给 rusage.py 用。
规则：
1. 只起 apple/.derived* 里的构建；库、偏好、各家 Agent 的配置目录、命令行链接与连接目录都在库目录或本检出的 SOCKETS 下
   （isolated_env 是唯一一份，sync-bench.py 也用它），不碰真实资料库、~/.pi、~/.local/bin、~/CuePad（项目工作区）与 ~/Applications/CuePad.app。
2. Mac 每个检出最多一份：看守进程（就是本进程）持 apple/.derived/mac-app.lock 的 flock，锁随看守进程释放，崩了也不留；
   新起的直接换掉 run 留着的旧实例。检出之间互不等待：几个 Agent 并行开发时各自截图、验收。
3. 一定退出：做完、出错、被打断（TERM、INT、HUP）、超时（截图类 HOLD 秒，run 是 RUN_TTL，
   CUEPAD_RUN_SECONDS 改它，验完就 stop）都走 quit：先 TERM 走 App 的正常退出，
   5 秒不退再 KILL，连同它起的子进程（Cue 的 pi、cuepad mcp）一起结束。exec 起的 bench 由调用方按 PID 结束，锁随 CuePad 进程释放。
   看守或调用方自己被 KILL、来不及收时，实例发现父进程没了也会正常退出（DebugHooks.exitsWithParent）。
4. 不靠固定等待：Debug 构建摆好画面后写就绪文件（CUEPAD_SHOT_READY，DebugScene.signalReady），这里用 kqueue 等它出现或 App 退出。
   这里起的实例都带它（exec 没给就用本检出那一份），App 据此认出是脚本起的（DebugHooks.scripted），测试宿主不带。
   本机构建一律在后台跑、不抢前台（DebugHooks.present）；不进程序坞是包里声明的（xc.sh 的 LSUIElement）。
   给了 -CuePadForeground YES 的实例要占前台时写 FRONT，front_keeper 经系统事件把它拉到前台（App 自己 activate 会被系统忽略）。
5. Mac 截图、录屏按窗口拍（wincap.swift，尺寸对不上就失败）；启动参数没给窗口尺寸时用 WINDOW。
iOS、iPadOS：模拟器里本就隔离，同一台上再 launch 就换掉旧的；状态栏固定成 9:41、满格满电，做完 terminate，run 留着。
   模拟器的系统外观跟 -theme 走（没给是浅色）：App 钉的外观与系统的不同时，启动屏与状态栏先按系统的画、App 起来后状态栏才淡过去，
   空库这类一起来就就绪的画面会拍到半途的状态栏（深色下 9:41 还是黑字）。
"""
import fcntl
import hashlib
import json
import os
import re
import select
import signal
import subprocess
import sys
import time

APPLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKOUT = os.path.dirname(APPLE)
BUNDLE_ID = "com.sugeh.cuepad"
RUNTIME = f"/tmp/cuepad-xc-{os.getuid()}"  # 与 _lock.sh 同一处；模拟器的就绪文件放这里（按设备分）
SLOT, READY = f"{APPLE}/.derived/mac-app.lock", f"{APPLE}/.derived/mac-ready"
# 实例借着前台却没到前台时写它（DebugForeground），看守替它拉到前台：别的应用在前台时 App 自己 activate 会被系统忽略
FRONT = f"{APPLE}/.derived/mac-front"
FRONT_POLL = 0.3
# 连接目录放 /tmp 下按检出分：socket 路径受 sun_path 104 字节限制，检出路径太长
SOCKETS = f"/tmp/cuepad-app-{os.getuid()}-{hashlib.sha1(CHECKOUT.encode()).hexdigest()[:8]}"
BUILD = re.compile(r".*/apple/\.derived[^/]*/Build/Products/[^/]+/CuePad\.app")
WINDOW = "1440x900"
READY_TIMEOUT = 60
HOLD = 300  # 截图类的看守上限（另加录屏、测量的秒数）：卡在哪一步都不留实例
# 一轮 bcu 交互验收用不完；不够就再 run 一次（换掉旧的），要等长任务（在 App 里装 Agent）时用 CUEPAD_RUN_SECONDS 放长。忘了收的实例曾活过 14 小时
RUN_TTL = int(os.environ.get("CUEPAD_RUN_SECONDS", 5 * 60))
REC_SECONDS = float(os.environ.get("CUEPAD_REC_SECONDS", 12))


def die(message):
    print(message, file=sys.stderr, flush=True)
    sys.exit(1)


REAL_LIBRARY = os.path.expanduser("~/Library/Application Support/CuePad")


def isolated_env(library, sockets=SOCKETS):
    library = os.path.realpath(library)
    if library == REAL_LIBRARY or library.startswith(REAL_LIBRARY + "/"):
        die(f"{library} 是真实资料库：本机构建一打开就升级结构、改写并同步出去。用只读副本（docs/verify.md「真实数据复现」）")
    agents = f"{library}/agents"
    # 锁的内部变量不带进实例：实例里的 Agent 再调 xc.sh 要照常进锁
    inherited = {k: v for k, v in os.environ.items() if k != "CUEPAD_SIM"}
    return dict(inherited, CUEPAD_LIBRARY_DIR=library, CUEPAD_BIN_DIR=f"{library}/bin", CUEPAD_PI_SOCKET_DIR=sockets,
                CUEPAD_WORKSPACE_DIR=f"{library}/CuePad",
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


def wait_ready(path, pid, log=""):
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
                die(f"App 在画面就绪前退出了：崩溃报告在 ~/Library/Logs/DiagnosticReports/CuePad-*.ips{log and '，输出在 ' + log}")
            left = deadline - time.monotonic()
            if left <= 0:
                die(f"{READY_TIMEOUT} 秒内画面没有就绪（没有写下 {path}）{log and '，输出在 ' + log}")
            exited = any(e.filter == select.KQ_FILTER_PROC for e in queue.control(None, 2, left))
    finally:
        os.close(folder)
        queue.close()
    with open(path) as f:
        return f.read().split()


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
    """占住本检出那一份。占着的只会是 run 留下的看守（本检出的命令由 _lock.sh 排队），换掉它。"""
    os.makedirs(os.path.dirname(SLOT), exist_ok=True)
    slot = open(SLOT, "a+")
    try:
        fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return slot
    except BlockingIOError:
        pass
    note = read_note(slot)  # 锁被占着，记录就是占着的那个写的
    if holder_alive(note):
        os.kill(note["holder"], signal.SIGTERM)
    fcntl.flock(slot, fcntl.LOCK_EX)
    return slot


def write_note(slot, **note):
    slot.truncate(0)
    slot.write(json.dumps(note))
    slot.flush()


class Mac:
    """持着本检出那一份的看守：start 起实例，quit 收掉（with 块结束时一定收）。"""

    def __init__(self, app, library, what):
        if not BUILD.fullmatch(app):
            die(f"只起 apple/.derived* 里的构建，不起 {app}")
        self.app, self.library, self.what, self.proc = app, os.path.abspath(library), what, None
        self.ready, self.log = READY, re.sub(r"/Build/Products/.*", "/app-mac.log", app)

    def __enter__(self):
        self.slot = take_slot()
        return self

    def start(self, args):
        if "-CuePadWindowSize" not in args:
            args = [*args, "-CuePadWindowSize", WINDOW]
        os.makedirs(SOCKETS, mode=0o700, exist_ok=True)
        if os.path.exists(self.ready):
            os.remove(self.ready)
        self.proc = subprocess.Popen([f"{self.app}/Contents/MacOS/CuePad", *args], env=dict(isolated_env(self.library), CUEPAD_SHOT_READY=self.ready, CUEPAD_FRONT_REQUEST=FRONT),
                                     stdin=subprocess.DEVNULL, stdout=open(self.log, "w"), stderr=subprocess.STDOUT)
        front_keeper(self.proc.pid)
        write_note(self.slot, holder=os.getpid(), app=self.proc.pid, what=self.what)
        return wait_ready(self.ready, self.proc.pid, self.log)

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
    with Mac(app, library, cmd) as m:
        signal.alarm(HOLD + int(REC_SECONDS if cmd == "rec" else 0))  # 从拿到那一份算起，排队等别人的不算
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
    with Mac(app, library, "run") as m:
        signal.alarm(RUN_TTL)
        m.start(args)
        os.write(report_w, str(m.proc.pid).encode())
        os.close(report_w)
        # 不再占着调用方的输出：否则调用方要等这个后台进程结束才拿到结果
        null = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(null, fd)
        m.proc.wait()


def exec_mac(app, library, args):
    """量完自己退出的 bench（perf-mac.sh、perf-idle.sh）：占住本检出那一份后 exec 成 CuePad。锁的文件描述符传给 CuePad，
    随它退出释放；PID 不变，调用方的 $! 就是 CuePad，由调用方按它结束，不留看守进程。"""
    if not BUILD.fullmatch(app):
        die(f"只起 apple/.derived* 里的构建，不起 {app}")
    slot = take_slot()
    # execAt：rusage.py 的"启动到就绪"从这里算，不算 python 启动与等本检出旧实例退出（进程的启动时刻是 fork 那一刻，exec 不重置）。
    # time.monotonic_ns 在 macOS 上就是 mach_absolute_time 换成纳秒，与内核记账同一个钟
    write_note(slot, holder=os.getpid(), app=os.getpid(), what="bench", execAt=time.monotonic_ns())
    os.set_inheritable(slot.fileno(), True)
    os.makedirs(SOCKETS, mode=0o700, exist_ok=True)
    exe = f"{app}/Contents/MacOS/CuePad"
    env = isolated_env(os.path.abspath(library))
    env.setdefault("CUEPAD_SHOT_READY", READY)
    env["CUEPAD_FRONT_REQUEST"] = FRONT
    front_keeper(os.getpid())  # exec 不换 PID：看守的就是接下来的 CuePad
    os.execve(exe, [exe, *args], env)


def front_keeper(pid):
    """后台看守 pid 那个实例：它写了 FRONT（借着前台却没到前台）就经系统事件把它拉到前台，它退出就走。
    只看文件不问系统谁在前台：前台的切换由实例自己报（到了前台就删、被抢走再写），量的时候这里不多花一次查询。"""
    if os.path.exists(FRONT):
        os.remove(FRONT)
    if os.fork():
        return
    os.setsid()
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)
    os.closerange(3, 1024)  # 不带着本检出那一份的锁与调用方的管道
    pull = f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            break
        if os.path.exists(FRONT):
            subprocess.run(["osascript", "-e", pull], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(FRONT_POLL)
    if os.path.exists(FRONT):
        os.remove(FRONT)
    os._exit(0)


def stop():
    os.makedirs(os.path.dirname(SLOT), exist_ok=True)
    with open(SLOT, "a+") as slot:
        try:
            fcntl.flock(slot, fcntl.LOCK_EX | fcntl.LOCK_NB)  # 拿得到就是没有实例，留下的记录是旧的
            print("本检出没有在跑的 Mac 实例")
            return
        except BlockingIOError:
            pass
        note = read_note(slot)
        if not holder_alive(note):
            print("本检出的 Mac 实例是 perf 在量，不是 run 起的，等它量完")
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
    ready = f"{RUNTIME}/ready-{device}"
    simctl("install", device, app)
    theme = args[args.index("-theme") + 1] if "-theme" in args[:-1] else "light"
    simctl("ui", device, "appearance", "dark" if theme == "dark" else "light")
    simctl("status_bar", device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
           "--cellularMode", "active", "--cellularBars", "4", "--wifiBars", "3")
    signal.alarm(HOLD + int(REC_SECONDS if cmd == "rec" else 0))
    rec = None
    try:
        if cmd == "rec" and os.environ.get("CUEPAD_REC_LAUNCH"):
            rec = recorder(device, out)  # 冷启动：先开录再起 App，录满秒数、不等就绪
            launch_sim(device, library, args, ready)
            stop_recording(rec)
        else:
            pid = launch_sim(device, library, args, ready)
            wait_ready(ready, pid)
            if cmd == "run":
                print(pid, device)
                return
            if cmd == "rec":
                rec = recorder(device, out)
                stop_recording(rec)
            else:
                simctl("io", device, "screenshot", out, capture_output=True)
        print(out)
    finally:
        if rec and rec.poll() is None:
            rec.send_signal(signal.SIGINT)
            rec.wait()
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
    if cmd == "sockets":
        return print(SOCKETS)
    if cmd == "exec":
        return exec_mac(argv[1], argv[2], launch_args)
    if cmd not in ("shot", "rec", "run") or len(argv) < 4:
        die(__doc__)
    platform, app, library = argv[1:4]
    options = dict(zip(argv[4::2], argv[5::2]))
    derived = re.sub(r"/Build/Products/.*", "", app)
    out = options.get("--out") or {"shot": f"{derived}/shot-{platform}.png", "rec": f"{derived}/rec-{platform}.mov"}.get(cmd)
    if platform == "mac":
        return mac(cmd, app, library, out, launch_args)
    sim(cmd, options["--device"], app, library, out, launch_args)


if __name__ == "__main__":
    sys.dont_write_bytecode = True
    main(sys.argv[1:])
