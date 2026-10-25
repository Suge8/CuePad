"""iOS、iPadOS 模拟器里的实例：装、起、截图、录屏。"""
import os
import signal
import subprocess
import time

from app_env import BUNDLE_ID, HOLD, REC_SECONDS, RUNTIME, die
from app_proc import wait_ready


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
