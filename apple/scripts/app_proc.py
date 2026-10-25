"""调试实例的进程收尾：被打断就退、收掉实例连同它起的子进程、等就绪文件。"""
import os
import select
import signal
import subprocess
import sys
import time

from app_env import READY_TIMEOUT, die


def interrupted(sig, _):
    if sig == signal.SIGALRM:
        print("看守超时，结束实例", file=sys.stderr, flush=True)
    raise SystemExit(128 + sig)



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
