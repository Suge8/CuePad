#!/usr/bin/env python3
"""进程的空闲与常驻开销，从外面读内核的记账（proc_pid_rusage），App 里不加测量代码；模拟器里的 App 也是本机进程，一样读。

用法：rusage.py <pid> <就绪标记> <静置秒> <量的秒数> [--on-ready <命令>] [--during <命令>]
等就绪标记出现（app.wait_ready：kqueue，最多 60 秒，App 先退出就失败），记下启动到就绪的毫秒；跑 --on-ready（如切到别的 App）；
再静置几秒让启动后的收尾做完，然后量一个窗口，窗口开始时起 --during（如 xctrace，量完等它写完），打印一行 JSON：
  readyMs        启动到就绪标记出现（标记的含义见 DebugScene.signalReady：画面摆好、读库回来、动画停下）。
                 Mac 从 app.py exec 成 CuePad 那一刻算（锁记录里的 execAt），iOS 从进程启动算
  wakeupsPerSec  窗口内每秒唤醒次数（包空闲唤醒加中断唤醒，同活动监视器的"空闲唤醒"口径再加中断唤醒）
  instructionsM  窗口内执行的指令（百万）    cpuMs  窗口内的 CPU 毫秒（用户态加内核态）
  footprintMB    窗口结束时的物理占用（同活动监视器的"内存"）    peakMB  进程一生的物理占用峰值
  energyMJ       窗口内内核估算的能耗（毫焦）
指令与唤醒不随机器忙闲变，前后对比看它们；readyMs、cpuMs、能耗受调度（性能核还是能效核）影响，机器忙时只作参考。
"""
import ctypes, json, subprocess, sys, time

sys.dont_write_bytecode = True
from app import SLOT, wait_ready  # noqa: E402

libc = ctypes.CDLL(None)


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


timebase = Timebase()
libc.mach_timebase_info(ctypes.byref(timebase))
NS = timebase.numer / timebase.denom
# rusage_info_v6：16 字节 uuid 之后全是 uint64（sys/resource.h），这里只取用到的下标
FIELDS = {"user": 0, "system": 1, "idle_wkups": 2, "interrupt_wkups": 3, "footprint": 7, "start": 8,
          "peak": 28, "instructions": 29, "energy_nj": 40}


def usage(pid):
    buf = (ctypes.c_uint64 * 64)()
    if libc.proc_pid_rusage(pid, 6, ctypes.byref(buf)) != 0:
        raise SystemExit(f"读不到进程 {pid}（已退出？）")
    raw = buf[2:]
    return {k: raw[i] for k, i in FIELDS.items()}


def started_ns(pid):
    """进程启动时刻；Mac 上 PID 先是 app.py，exec 成 CuePad 的时刻记在锁记录里。"""
    start = usage(pid)["start"] * NS
    try:
        note = json.load(open(SLOT))
    except (OSError, ValueError):
        return start
    return max(start, note.get("execAt", 0)) if note.get("app") == pid else start


def main():
    pid, ready, settle, seconds = int(sys.argv[1]), sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
    hooks = dict(zip(sys.argv[5::2], sys.argv[6::2]))
    wait_ready(ready, pid)
    # time.monotonic_ns 在 macOS 上就是 mach_absolute_time 换成纳秒，与内核记账同一个钟
    ready_ms = (time.monotonic_ns() - started_ns(pid)) / 1e6
    if "--on-ready" in hooks:
        subprocess.run(hooks["--on-ready"], shell=True, check=True, stdout=subprocess.DEVNULL)
    time.sleep(settle)
    a = usage(pid)
    during = subprocess.Popen(hooks["--during"], shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if "--during" in hooks else None
    time.sleep(seconds)  # 量的就是这一段
    b = usage(pid)
    if during:
        during.wait()
    d = lambda k: b[k] - a[k]
    print(json.dumps({
        "readyMs": round(ready_ms),
        "wakeupsPerSec": round((d("idle_wkups") + d("interrupt_wkups")) / seconds, 2),
        "instructionsM": round(d("instructions") / 1e6, 1),
        "cpuMs": round((d("user") + d("system")) * NS / 1e6, 1),
        "footprintMB": round(b["footprint"] / 2**20, 1),
        "peakMB": round(b["peak"] / 2**20, 1),
        "energyMJ": round(d("energy_nj") / 1e6, 1),
    }), flush=True)


main()
