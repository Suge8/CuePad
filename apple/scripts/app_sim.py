"""iOS、iPadOS 模拟器里的实例：装、起、截图、录屏；run 起的实例由看守租着这台模拟器。"""
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time

from app_env import BUNDLE_ID, HOLD, REC_SECONDS, RUN_ROLE, RUN_TTL, RUNTIME, SIM_RUN_GLOB, die, sim_run
from app_proc import alive, silence, wait_exit, wait_ready
from app_shots import batch

# simctl 偶尔挂住不返回（实测 install 卡过 20 分钟）：每次调用自己有上限，到了就把这台关机再开、重做一次，再卡才失败
SIMCTL_TIMEOUT = 180
BOOT_TIMEOUT = 180
# 一张的看守上限要装得下一次 simctl 自愈（超时 + shutdown + boot + 重做），不然第二次尝试被闹钟截断
SHOT_HOLD = HOLD + 2 * SIMCTL_TIMEOUT + 2 * BOOT_TIMEOUT


class Sim:
    """领到的那台模拟器（调用方已持着它的槽位锁，重启不会撞上别人）。"""

    def __init__(self, device, log):
        self.device, self.status_bar_set, self.log, self.landscape = device, False, log, False

    def run(self, *args, env=None):
        """跑一条 simctl，返回它的输出。"""
        for attempt in (1, 2):
            try:
                return subprocess.run(["xcrun", "simctl", *args], check=True, timeout=SIMCTL_TIMEOUT, env=env, capture_output=True, text=True).stdout
            except subprocess.TimeoutExpired:
                if attempt == 2:
                    die(f"simctl {args[0]} 重启模拟器后仍 {SIMCTL_TIMEOUT} 秒没有返回")
                self.reboot(args[0])
            except subprocess.CalledProcessError as e:
                die(f"simctl {args[0]} 失败：{e.stderr.strip()}")

    def reboot(self, stuck):
        print(f"simctl {stuck} {SIMCTL_TIMEOUT} 秒没有返回，重启模拟器 {self.device} 后重做一次", file=sys.stderr, flush=True)
        try:
            subprocess.run(["xcrun", "simctl", "shutdown", self.device], capture_output=True, timeout=BOOT_TIMEOUT)  # 已关着会报错，不管
            subprocess.run(["xcrun", "simctl", "bootstatus", self.device, "-b"], check=True, capture_output=True, timeout=BOOT_TIMEOUT)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
            die(f"模拟器 {self.device} 重启没成功")
        if self.status_bar_set:
            self.set_status_bar()  # 状态栏的覆盖随关机清掉

    def orient(self, args):
        """按这一张的参数摆模拟器的物理朝向：`-CuePadLandscape YES` 横过来，否则竖着（devicectl，同人转设备；不发键鼠事件、不开 Simulator.app）。
        不在 App 里转：iPad 支持多任务，系统按设备朝向定界面方向，不理 App 的 requestGeometryUpdate（UIRequiresFullScreen 已弃用）。
        每张都摆：槽位全机共用，上一个任务可能停在横屏（拍完 `terminate` 转回竖屏）。"""
        self.landscape = flag(args, "-CuePadLandscape") == "YES"
        want = "landscapeLeft" if self.landscape else "portrait"
        try:
            subprocess.run(["xcrun", "devicectl", "device", "orientation", "set", "--device", self.device, want, "--quiet"],
                           check=True, timeout=SIMCTL_TIMEOUT, capture_output=True, text=True)
        except subprocess.CalledProcessError as e:
            die(f"devicectl 转模拟器朝向失败：{e.stderr.strip()}")
        except subprocess.TimeoutExpired:
            die(f"devicectl 转模拟器朝向 {SIMCTL_TIMEOUT} 秒没有返回")

    def set_status_bar(self):
        self.run("status_bar", self.device, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100",
                 "--cellularMode", "active", "--cellularBars", "4", "--wifiBars", "3")
        self.status_bar_set = True

    def launch(self, library, args, ready):
        if os.path.exists(ready):
            os.remove(ready)
        self.orient(args)
        env = dict(os.environ, SIMCTL_CHILD_CUEPAD_LIBRARY_DIR=os.path.abspath(library), SIMCTL_CHILD_CUEPAD_SHOT_READY=ready)
        return int(self.run("launch", "--terminate-running-process", f"--stderr={self.log}", self.device, BUNDLE_ID, *args, env=env).rsplit(":", 1)[1])

    def terminate(self):
        """收尾，尽力而为：没在跑会报错，卡住了下一次 launch 也带 --terminate-running-process；横着的转回竖屏（下一次 launch 照样会摆）。"""
        try:
            subprocess.run(["xcrun", "simctl", "terminate", self.device, BUNDLE_ID], capture_output=True, timeout=SIMCTL_TIMEOUT)
            if self.landscape:
                subprocess.run(["xcrun", "devicectl", "device", "orientation", "set", "--device", self.device, "portrait", "--quiet"],
                               capture_output=True, timeout=SIMCTL_TIMEOUT)
                self.landscape = False
        except subprocess.TimeoutExpired:
            pass


def flag(args, name):
    """启动参数里 `name` 后面那个值；没有这一项（或它在最后、没跟值）为 None。"""
    return args[args.index(name) + 1] if name in args[:-1] else None


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


def sim(cmd, device, app, library, shots):
    """装一次包、设一次状态栏，逐张起实例拍（外观随 -theme 变时才切）。"""
    # App 的标准错误（`DebugScene.abandon` 报的原因、崩溃前的输出），就绪前退出时 wait_ready 指向它。放在产物目录（同 app-mac.log）：
    # simctl launch 把 /tmp 下的路径换到模拟器自己的数据目录里
    s = Sim(device, re.sub(r"/Build/Products/.*", "/app-sim.log", app))
    ready = f"{RUNTIME}/ready-{device}"
    s.run("install", device, app)
    s.set_status_bar()
    appearance = None
    seconds = REC_SECONDS if cmd == "rec" else 0

    def take(shot):
        nonlocal appearance
        # 模拟器的系统外观跟 -theme 走：App 钉的外观与系统的不同时，状态栏要到 App 起来后才淡过去，会拍到半途
        want = "dark" if flag(shot.args, "-theme") == "dark" else "light"
        if want != appearance:
            s.run("ui", device, "appearance", want)
            appearance = want
        signal.alarm(SHOT_HOLD + int(seconds))
        os.makedirs(os.path.dirname(os.path.abspath(shot.out)), exist_ok=True)
        rec = None
        try:
            if cmd == "rec" and os.environ.get("CUEPAD_REC_LAUNCH"):
                rec = recorder(device, shot.out)  # 冷启动：先开录再起 App，录满秒数、不等就绪
                s.launch(library, shot.args, ready)
                stop_recording(rec)
            else:
                pid = s.launch(library, shot.args, ready)
                wait_ready(ready, pid, s.log)
                if cmd == "run":
                    return keep(s, pid)
                if cmd == "rec":
                    rec = recorder(device, shot.out)
                    stop_recording(rec)
                else:
                    s.run("io", device, "screenshot", shot.out)
        finally:
            signal.alarm(0)
            if rec and rec.poll() is None:
                rec.send_signal(signal.SIGINT)
                rec.wait()
            if cmd != "run":
                s.terminate()

    if cmd == "run":
        return take(shots[0])
    batch(shots, take)


def keep(s, pid):
    """run：起一个脱离 xc.sh 的看守，守到实例退出、RUN_TTL 或 stop；这里等看守就位后打印 PID 与 UDID 就返回。
    模拟器的槽位锁在 xc.sh 退出时由 _lock.py 交给看守（它读 CUEPAD_LEASE 里的看守 PID），别的检出领不到这台。"""
    report_r, report_w = os.pipe()
    if os.fork():
        os.close(report_w)
        if not os.read(report_r, 1):
            die("看守没有起来")
        print(pid, s.device)
        return
    os.close(report_r)
    os.setsid()
    signal.alarm(RUN_TTL)
    with open(sim_run(), "w") as f:
        json.dump({"holder": os.getpid(), "app": pid, "device": s.device}, f)
    with open(os.environ["CUEPAD_LEASE"], "w") as f:
        f.write(str(os.getpid()))
    os.write(report_w, b"1")
    os.close(report_w)
    silence()
    try:
        wait_exit(pid)
    finally:
        s.terminate()
        os.remove(sim_run())
    os._exit(0)


def stop():
    """结束本检出 run 起的模拟器实例（给了 CUEPAD_RUN_ROLE 只收这个角色的），等看守收完；返回要报的话，没有就是 None。"""
    done = []
    for path in [sim_run()] if RUN_ROLE else glob.glob(SIM_RUN_GLOB):
        try:
            with open(path) as f:
                note = json.load(f)
        except (OSError, ValueError):
            continue
        if alive(note):
            os.kill(note["holder"], signal.SIGTERM)
            wait_exit(note["holder"])
            done.append(f"已结束模拟器 {note['device']} 上的实例 {note['app']}")
    return "\n".join(done) or None
