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


def silence():
    """标准输入输出不再占着调用方的管道（否则调用方要等本进程结束才拿到结果）。"""
    null = os.open(os.devnull, os.O_RDWR)
    for fd in (0, 1, 2):
        os.dup2(null, fd)


def wait_exit(pid):
    """等进程退出（kqueue）；它已经不在就立刻返回。"""
    queue = select.kqueue()
    try:
        queue.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)], 1, None)
    except ProcessLookupError:
        pass
    finally:
        queue.close()


def alive(note):
    """note["holder"] 是不是还在跑的 app.py（run 留下的看守）。"""
    pid = note.get("holder")
    command = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout if pid else ""
    return "app.py" in command


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


def wait_ready(path, pid, log="", timeout=READY_TIMEOUT):
    """等就绪文件出现；App 先退出（多半是崩了）或超过 timeout 秒就失败。"""
    queue, folder = select.kqueue(), os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        watch = [select.kevent(folder, select.KQ_FILTER_VNODE, select.KQ_EV_ADD | select.KQ_EV_CLEAR, select.KQ_NOTE_WRITE),
                 select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD, select.KQ_NOTE_EXIT)]
        try:
            queue.control(watch, 0)
            exited = False
        except ProcessLookupError:
            exited = True
        deadline = time.monotonic() + timeout
        while not os.path.exists(path):
            if exited:
                die(f"App 在画面就绪前退出了：{log and '原因看输出 ' + log + ' 的末尾，'}崩了的话崩溃报告在 ~/Library/Logs/DiagnosticReports/CuePad-*.ips")
            left = deadline - time.monotonic()
            if left <= 0:
                die(f"{timeout:g} 秒内画面没有就绪（没有写下 {path}）{log and '，输出在 ' + log}")
            exited = any(e.filter == select.KQ_FILTER_PROC for e in queue.control(None, 2, left))
    finally:
        os.close(folder)
        queue.close()
    with open(path) as f:
        return f.read().split()
