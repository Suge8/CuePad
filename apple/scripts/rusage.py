#!/usr/bin/env python3
"""进程的空闲与常驻开销，从外面读内核的记账（proc_pid_rusage），App 里不加测量代码；模拟器里的 App 也是本机进程，一样读。

用法：rusage.py <pid> <就绪标记> <静置秒> <量的秒数>
等就绪标记出现（最多 60 秒），记下进程启动到就绪的毫秒；再静置几秒让启动后的收尾做完，然后量一个窗口，打印一行 JSON：
  readyMs        进程启动到就绪标记出现（标记的含义见 DebugScene.signalReady：画面摆好、读库回来、动画停下）
  wakeupsPerSec  窗口内每秒唤醒次数（包空闲唤醒加中断唤醒，同活动监视器的"空闲唤醒"口径再加中断唤醒）
  instructionsM  窗口内执行的指令（百万）    cpuMs  窗口内的 CPU 毫秒（用户态加内核态）
  footprintMB    窗口结束时的物理占用（同活动监视器的"内存"）    peakMB  进程一生的物理占用峰值
  energyMJ       窗口内内核估算的能耗（毫焦）
"""
import ctypes, json, os, sys, time

libc = ctypes.CDLL(None)


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


timebase = Timebase()
libc.mach_timebase_info(ctypes.byref(timebase))
libc.mach_absolute_time.restype = ctypes.c_uint64
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


def main():
    pid, ready, settle, seconds = int(sys.argv[1]), sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
    for _ in range(6000):
        if os.path.exists(ready):
            break
        usage(pid)
        time.sleep(0.01)
    else:
        raise SystemExit("60 秒内没有就绪")
    ready_ms = (libc.mach_absolute_time() - usage(pid)["start"]) * NS / 1e6
    time.sleep(settle)
    a = usage(pid)
    time.sleep(seconds)
    b = usage(pid)
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
