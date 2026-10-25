#!/usr/bin/env python3
"""进程的空闲与常驻开销，从外面读内核的记账（proc_pid_rusage），App 里不加测量代码；模拟器里的 App 也是本机进程，一样读。

用法：rusage.py <pid> <就绪标记> <静置秒> <量的秒数> [--on-ready <命令>] [--during <命令>]
等就绪标记出现（app_proc.wait_ready：kqueue，最多 60 秒，App 先退出就失败），记下启动到就绪的毫秒；跑 --on-ready（如切到别的 App）；
至少静置 <静置秒>，再等到连续 QUIET_SPAN 秒安静（每秒指令低于 QUIET_RATE），然后量一个窗口，窗口开始时起 --during（如 xctrace，量完等它写完），打印一行 JSON：
  readyMs        启动到就绪标记出现（标记的含义见 DebugScene.signalReady：画面摆好、读库回来、动画停下）。
                 Mac 从 app.py exec 成 CuePad 那一刻算（锁记录里的 execAt），iOS 从进程启动算
  readyInstructionsM  进程从启动到就绪执行的指令（百万），启动那段的前后对比看它；
                 Mac 上含 exec 之前 app.py 那段 python（每次相同的一截，前后对比时抵消）
  tailInstructionsM  就绪到开窗之间的指令（百万）：启动后的收尾，与 readyInstructionsM 相加是整个启动；两者的分界随机器忙闲挪，比和不比单看
  settleS        就绪到开窗等了几秒
  wakeupsPerSec  窗口内每秒唤醒次数（包空闲唤醒加中断唤醒，同活动监视器的"空闲唤醒"口径再加中断唤醒）
  instructionsM  窗口内执行的指令（百万）    cpuMs  窗口内的 CPU 毫秒（用户态加内核态）
  footprintMB    窗口结束时的物理占用（同活动监视器的"内存"）    peakMB  进程一生的物理占用峰值
  energyMJ       窗口内内核估算的能耗（毫焦）
指令与唤醒不随机器忙闲变，前后对比看它们；readyMs、cpuMs、能耗受调度（性能核还是能效核）影响，机器忙时只作参考。
"""
import ctypes, json, subprocess, sys, time

sys.dont_write_bytecode = True
from app_env import SLOT  # noqa: E402
from app_proc import wait_ready  # noqa: E402

libc = ctypes.CDLL(None)


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


timebase = Timebase()
libc.mach_timebase_info(ctypes.byref(timebase))
NS = timebase.numer / timebase.denom
# 就绪后还有收尾：iOS 另外两页在启动后空闲时才建（PagerController），SwiftUI 再在优先级低的后台线程给新出现的视图类型
# 算比较用的布局（AttributeGraph 的 TypeDescriptorCache）。模拟器里这一段有几十亿条指令，机器忙时被拖到半分钟以后，
# 固定静置几秒就开窗，量到的是这段收尾而不是静置。收尾一阵一阵地来，阵与阵之间实测空过 9 秒。
QUIET_RATE = 30e6  # 每秒指令低于它算安静：静置的 iOS 模拟器每秒几百万，收尾时每秒几亿起
QUIET_SPAN = 15
QUIET_LIMIT = 120  # 等到这么久还不安静就照量，并在 stderr 说一声：一直不安静本身就是要量的
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


def wait_quiet(pid):
    """等到连续 QUIET_SPAN 秒、每秒指令都低于 QUIET_RATE，返回那一刻的记账；内核记账没有"变安静了"的通知，只能按秒读。"""
    start, quiet = time.monotonic(), 0
    last = usage(pid)
    while quiet < QUIET_SPAN:
        if time.monotonic() - start > QUIET_LIMIT:
            print(f"等了 {QUIET_LIMIT} 秒还不安静，照量", file=sys.stderr)
            break
        time.sleep(1)
        now = usage(pid)
        quiet = quiet + 1 if now["instructions"] - last["instructions"] < QUIET_RATE else 0
        last = now
    return last


def main():
    pid, ready, settle, seconds = int(sys.argv[1]), sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
    hooks = dict(zip(sys.argv[5::2], sys.argv[6::2]))
    wait_ready(ready, pid)
    # time.monotonic_ns 在 macOS 上就是 mach_absolute_time 换成纳秒，与内核记账同一个钟
    ready_at = time.monotonic_ns()
    ready_ms = (ready_at - started_ns(pid)) / 1e6
    ready_instructions = usage(pid)["instructions"]
    if "--on-ready" in hooks:
        subprocess.run(hooks["--on-ready"], shell=True, check=True, stdout=subprocess.DEVNULL)
    time.sleep(settle)
    a = wait_quiet(pid)
    settled = time.monotonic_ns()
    during = subprocess.Popen(hooks["--during"], shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) if "--during" in hooks else None
    time.sleep(seconds)  # 量的就是这一段
    b = usage(pid)
    if during:
        during.wait()
    d = lambda k: b[k] - a[k]
    print(json.dumps({
        "readyMs": round(ready_ms),
        "readyInstructionsM": round(ready_instructions / 1e6, 1),
        "tailInstructionsM": round((a["instructions"] - ready_instructions) / 1e6, 1),
        "settleS": round((settled - ready_at) / 1e9, 1),
        "wakeupsPerSec": round((d("idle_wkups") + d("interrupt_wkups")) / seconds, 2),
        "instructionsM": round(d("instructions") / 1e6, 1),
        "cpuMs": round((d("user") + d("system")) * NS / 1e6, 1),
        "footprintMB": round(b["footprint"] / 2**20, 1),
        "peakMB": round(b["peak"] / 2**20, 1),
        "energyMJ": round(d("energy_nj") / 1e6, 1),
    }), flush=True)


if __name__ == "__main__":
    main()
