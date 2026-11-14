"""Mac 实例：每个检出一份（app.py 的规则 2），截图、录屏、run、exec、stop 与前台看守。"""
import fcntl
import json
import os
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time

from _lock import holding, me, take
from app_env import APPLE, BUILD, BUNDLE_ID, EXEC_AT, FRONT, FRONT_RETRY, HOLD, READY, REC_SECONDS, RUN_TTL, SLOT, SLOT_NAME, SOCKETS, WINDOW, die, disclaimed, isolated_env
from app_proc import quit_mac, silence, wait_ready
from app_shots import batch

SLOT_WAIT = 15  # 通知占着的看守退出后，等它放锁的上限秒数
# CUEPAD_NOTIFY=1 的 run 起这份副本：别的名字，绝不覆盖用户装的 CuePad.app
NOTIFY_APP = os.path.expanduser("~/Applications/CuePad Notify.app")


def who(h):
    return f"pid {h['pid']}（{h['what']}）：{h['cmd']}"


def wait_release(slot, h):
    """等占着的人（h：登记里的那一条，没有为 None）放锁：放了就返回（flock 阻塞在线程里，事件驱动，不轮询）。
    SLOT_WAIT 秒还不放（看守被暂停、忽略了 TERM，别的测量还在跑，或没有登记）就报出它的身份退出，不凭旧 PID 去杀。"""
    got = threading.Event()

    def block():
        fcntl.flock(slot, fcntl.LOCK_EX)
        got.set()

    threading.Thread(target=block, daemon=True).start()
    if got.wait(SLOT_WAIT):
        return
    if h and h["what"] == "run":
        die(f"本检出上一个 run 的看守 {SLOT_WAIT} 秒没放下 Mac 实例位（已发 TERM）：{who(h)}\n"
            "下一步：xc.sh stop 再试一次；ps -o stat= -p <PID> 是 T（被暂停）的先 kill -CONT <PID> 让它处理 TERM；仍不退出，请用户确认后只对这个 PID 发 KILL，不按名字找")
    if h:
        die(f"本检出的 Mac 实例位被占着 {SLOT_WAIT} 秒：{who(h)}\n下一步：等它结束再试")
    die(f"本检出的 Mac 实例位被占着 {SLOT_WAIT} 秒，没有登记的持有者。\n"
        f"下一步：等它用完再试；lsof {SLOT} 看谁开着它（开着不等于正持有）；不要删这个文件")


def take_slot(what, **extra):
    """占住本检出那一份并登记（what：run、shot、rec、bench；sync-bench.py 另经 _lock.hold 占）。占着的是 run 留下的看守就换掉它，
    别的（本检出的命令由 _lock.sh 排队，只剩刚收尾的测量）等它放。"""
    os.makedirs(os.path.dirname(SLOT), exist_ok=True)
    slot = open(SLOT, "a+")
    if not take(slot):
        h = holding(SLOT_NAME)
        if h and h["what"] == "run":
            os.kill(h["pid"], signal.SIGTERM)
        wait_release(slot, h)
    me(what=what, **extra).add(SLOT_NAME)
    return slot


class Mac:
    """持着本检出那一份的看守：start 起实例，quit 收掉（with 块结束时一定收）。"""

    def __init__(self, app, library, what):
        if not BUILD.fullmatch(app):
            die(f"只起 apple/.derived* 里的构建，不起 {app}")
        self.app, self.library, self.what, self.proc = app, os.path.abspath(library), what, None
        self.ready, self.log = READY, re.sub(r"/Build/Products/.*", "/app-mac.log", app)
        self.notify = what == "run" and os.environ.get("CUEPAD_NOTIFY") == "1"

    def __enter__(self):
        self.slot = take_slot(self.what)
        if self.notify:
            self.app = notify_copy(self.app)
        # 显示器睡着时窗口不上屏、截不到画面：-u 叫醒它，-d 到看守退出前不让它再睡（只 -u 的断言几秒就过期）
        subprocess.Popen(["caffeinate", "-d", "-u", "-w", str(os.getpid())], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return self

    def start(self, args, launched=None):
        """launched(pid)：进程起来、还没就绪时调（冷启动录屏在这一刻开录）。"""
        self.quit()
        if "-CuePadWindowSize" not in args:
            args = [*args, "-CuePadWindowSize", WINDOW]
        os.makedirs(SOCKETS, mode=0o700, exist_ok=True)
        if os.path.exists(self.ready):
            os.remove(self.ready)
        self.proc = subprocess.Popen(disclaimed([f"{self.app}/Contents/MacOS/CuePad", *args]), env=dict(isolated_env(self.library), CUEPAD_SHOT_READY=self.ready, **front_env(args)),
                                     stdin=subprocess.DEVNULL, stdout=open(self.log, "w"), stderr=subprocess.STDOUT)
        front_keeper(self.proc.pid, args)
        me().publish(app=self.proc.pid)
        if launched:
            launched(self.proc.pid)
        return wait_ready(self.ready, self.proc.pid, self.log)

    def quit(self):
        if self.proc:
            quit_mac(self.proc)
            self.proc = None

    def __exit__(self, *_):
        self.quit()
        if self.notify:
            shutil.rmtree(NOTIFY_APP, ignore_errors=True)
        me().drop(SLOT_NAME)
        self.slot.close()


def notify_copy(app):
    """产物目录里的构建拿不到通知权限（日志 `Failed to find or validate client`）：复制到 ~/Applications、换掉 bundle id
    （不和正式版共用通知设置，点通知也不激活正式版）再 ad-hoc 重签名，起这份；看守收掉实例时删副本，系统设置的通知列表里会留下这个 bundle id。"""
    shutil.rmtree(NOTIFY_APP, ignore_errors=True)
    subprocess.run(["ditto", app, NOTIFY_APP], check=True)
    subprocess.run(["plutil", "-replace", "CFBundleIdentifier", "-string", f"{BUNDLE_ID}.notify-check", f"{NOTIFY_APP}/Contents/Info.plist"], check=True)
    subprocess.run(["codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements", NOTIFY_APP], check=True, capture_output=True)
    return NOTIFY_APP


def wincap():
    source, binary = f"{APPLE}/scripts/wincap.swift", f"{APPLE}/.derived/wincap"
    if not os.path.exists(binary) or os.path.getmtime(source) > os.path.getmtime(binary):
        os.makedirs(os.path.dirname(binary), exist_ok=True)
        subprocess.run(["swiftc", "-O", source, "-o", binary], check=True)
    return binary


def mac(cmd, app, library, shots):
    if cmd == "run":
        return run_mac(app, library, shots[0].args)
    seconds = REC_SECONDS if cmd == "rec" else 0
    with Mac(app, library, cmd) as m:
        def take(shot):
            signal.alarm(HOLD + int(seconds))  # 每张从起实例算，排队等别人的不算
            try:
                if cmd == "rec" and os.environ.get("CUEPAD_REC_LAUNCH"):
                    return record_launch(m, shot)
                size = m.start(shot.args)
                if len(size) != 2:
                    die("就绪文件里没有窗口尺寸：画面没有可拍的普通窗口")
                capture = ["rec", str(m.proc.pid), str(REC_SECONDS)] if cmd == "rec" else ["shot", str(m.proc.pid)]
                os.makedirs(os.path.dirname(os.path.abspath(shot.out)), exist_ok=True)
                subprocess.run([wincap(), *capture, *size, shot.out], check=True)
            finally:
                m.quit()
                signal.alarm(0)

        batch(shots, take)


def record_launch(m, shot):
    """冷启动：进程一起来就开录（wincap 等窗口出现），录满秒数、不等就绪。窗口尺寸按启动参数（点），同 Mac.start 给的默认。"""
    points = (dict(zip(shot.args, shot.args[1:])).get("-CuePadWindowSize") or WINDOW).split("x")
    os.makedirs(os.path.dirname(os.path.abspath(shot.out)), exist_ok=True)
    rec, binary = [], wincap()  # 先编好：编译不能占进程起来到窗口出现那一段
    m.start(shot.args, lambda pid: rec.append(subprocess.Popen([binary, "launch", str(pid), str(REC_SECONDS), *points, shot.out])))
    if rec[0].wait():
        die(f"冷启动录屏失败（wincap 退出码 {rec[0].returncode}）")


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
        silence()
        m.proc.wait()


def exec_mac(app, library, args):
    """量完自己退出的 bench（perf.py）：占住本检出那一份后 exec 成 CuePad。锁的文件描述符传给 CuePad，
    随它退出释放；PID 不变，调用方的 $! 就是 CuePad，由调用方按它结束；不留看守进程（借前台的另有前台看守，随它退出）。"""
    if not BUILD.fullmatch(app):
        die(f"只起 apple/.derived* 里的构建，不起 {app}")
    slot = take_slot("bench", app=os.getpid())
    # 不算 python 启动与等本检出旧实例退出（进程的启动时刻是 fork 那一刻，exec 不重置）。
    # time.monotonic_ns 在 macOS 上就是 mach_absolute_time 换成纳秒，与内核记账同一个钟
    with open(EXEC_AT, "w") as f:
        json.dump({"pid": os.getpid(), "execAt": time.monotonic_ns()}, f)
    os.set_inheritable(slot.fileno(), True)
    os.makedirs(SOCKETS, mode=0o700, exist_ok=True)
    exe = f"{app}/Contents/MacOS/CuePad"
    env = isolated_env(os.path.abspath(library))
    env.setdefault("CUEPAD_SHOT_READY", READY)
    env.update(front_env(args))
    front_keeper(os.getpid(), args)  # exec 不换 PID：看守的就是接下来的 CuePad
    # 不经 disclaim.py：它多一次 Python 启动，会算进"启动到就绪"；量的这几样不要权限，责任进程是谁不影响读数
    os.execve(exe, [exe, *args], env)


def wants_front(args):
    """给了 -CuePadForeground YES：只有这样的实例会借前台（DebugForeground），才要看守。"""
    return any(a == "-CuePadForeground" and v.lower() in ("yes", "true", "1") for a, v in zip(args, args[1:]))


def front_env(args):
    return {"CUEPAD_FRONT_REQUEST": FRONT} if wants_front(args) else {}


def front_keeper(pid, args):
    """要借前台的实例才有：后台看守 pid 那个实例，它写了 FRONT（借着前台却没到前台）就经系统事件把它拉到前台，它退出就走。
    只看文件不问系统谁在前台：前台的切换由实例自己报（到了前台就删、被抢走再写）。用 kqueue 等目录变化与实例退出，
    平时不醒；FRONT 在着（拉了还没到前台）时每 FRONT_RETRY 秒再拉一次。"""
    if not wants_front(args):
        return
    if os.path.exists(FRONT):
        os.remove(FRONT)
    if os.fork():
        return
    os.setsid()
    silence()
    os.closerange(3, 1024)  # 不带着本检出那一份的锁与调用方的管道
    pull = f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'
    queue, folder = select.kqueue(), os.open(os.path.dirname(FRONT), os.O_RDONLY)
    try:
        queue.control([select.kevent(folder, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR, select.KQ_NOTE_WRITE),
                       select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 0)
        while True:
            if os.path.exists(FRONT):
                subprocess.run(["osascript", "-e", pull], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            events = queue.control(None, 2, FRONT_RETRY if os.path.exists(FRONT) else None)
            if any(e.filter == select.KQ_FILTER_PROC for e in events):
                break
    except ProcessLookupError:
        pass  # 装上之前它就退了
    if os.path.exists(FRONT):
        os.remove(FRONT)
    os._exit(0)


def stop():
    """结束 run 起的 Mac 实例；返回要报的话，没有就是 None。"""
    os.makedirs(os.path.dirname(SLOT), exist_ok=True)
    with open(SLOT, "a+") as slot:
        if take(slot):  # 拿得到就是没有实例
            return None
        h = holding(SLOT_NAME)
        if not h or h["what"] != "run":
            return f"本检出的 Mac 实例不是 run 起的，不收：{who(h) if h else f'没有登记的持有者（lsof {SLOT}）'}"
        os.kill(h["pid"], signal.SIGTERM)
        wait_release(slot, h)  # 看守收完实例才放锁
    return f"已结束 Mac 实例 {h['app']}"


def preflight():
    stage = subprocess.run(["defaults", "read", "com.apple.WindowManager", "GloballyEnabled"], capture_output=True, text=True).stdout
    if stage.strip() == "1":
        die("台前调度开着：后台窗口被缩小显示，截图、录屏的尺寸不对。请用户在控制中心关掉台前调度再拍")
