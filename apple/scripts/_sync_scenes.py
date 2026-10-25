"""sync-bench.py 的场景：每个场景拿一次运行（_sync_run.Run，两端已连通），按事件驱动两个实例，返回 {指标: [秒…]}，
另可在 extra 里放不是时延的数（开销）。指标名就是报告里的行名，按"场景·段"写，A/B 两边同名的行对比。
时刻都是同一台机器的墙钟：写下取记录的 createdAt，其余取实例读到那一刻（库的订阅送到主线程），上屏取画进页面后的那次提交。
"""
import os, re, subprocess, time
from collections import Counter, defaultdict

from _sync_run import PEER, kind
from rusage import NS, usage

ROUND_LIMIT = 60  # 一轮里等一样东西最多这么久（与 Speech.receiptLimit 同）


def by_id(name, id):
    return lambda e: e["e"] == name and e.get("id") == id


def arrived(id):
    return lambda e: e["e"] in ("msg-arrived", "msg-present") and e.get("id") == id


class Metrics(defaultdict):
    def __init__(self): super().__init__(list)

    def span(self, name, start, end):
        if start and end: self[name].append(round(end["t"] - start["t"], 3))
        elif start: self[name + "（超时）"].append(1)


def round_trip(run, tag, m):
    """一轮：手机对 Cue 说一句、对 A 的一个会话说一句；Cue 的替身大脑回一句到手机。"""
    a, b = run.a, run.b
    t0 = b.send(f"say {tag}"); b.send(f"send {tag} {PEER}")
    say = b.wait(kind("msg-write", "you"), 10, after=t0 - 0.5)
    req = b.wait(kind("req-write"), 10, after=t0 - 0.5)
    if say:
        id = say["id"]
        receipt = b.wait(by_id("msg-delivered", id), ROUND_LIMIT)
        accepted, got = b.first("msg-accepted", id), a.wait(arrived(id), 1)
        handed = a.first("msg-delivered", id)
        m.span("手机→Mac 对 Cue 说·写下→已发出", say, accepted)
        m.span("手机→Mac 对 Cue 说·已发出→Mac 入库", accepted, got)
        m.span("手机→Mac 对 Cue 说·Mac 入库→上屏", got, a.wait(by_id("msg-shown", id), 5))
        m.span("手机→Mac 对 Cue 说·Mac 入库→交给 Cue", got, handed)
        m.span("手机→Mac 对 Cue 说·交给 Cue→回执到手机", handed, receipt)
        m.span("手机→Mac 对 Cue 说·全程（写下→已送达）", say, receipt)
        reply = a.wait(kind("msg-write", "cue"), 30, after=handed["t"] if handed else t0)
        if reply:
            rid = reply["id"]
            shown = b.wait(by_id("msg-shown", rid), ROUND_LIMIT)
            rgot = b.first("msg-arrived", rid)
            m.span("Mac→手机 Cue 回话·写下→手机入库", reply, rgot)
            m.span("Mac→手机 Cue 回话·手机入库→上屏", rgot, shown)
            m.span("Mac→手机 Cue 回话·全程（写下→上屏）", reply, shown)
    if req:
        id = req["id"]
        done = b.wait(by_id("req-done", id), ROUND_LIMIT)
        accepted, got, ran = b.first("req-accepted", id), a.wait(by_id("req-arrived", id), 1), a.first("req-done", id)
        executed = {"t": ran["at"]} if ran else None
        m.span("手机→Mac 对会话说·写下→已发出", req, accepted)
        m.span("手机→Mac 对会话说·已发出→Mac 入库", accepted, got)
        m.span("手机→Mac 对会话说·Mac 入库→执行完", got, executed)
        m.span("手机→Mac 对会话说·执行完→结果回到手机", executed, done)
        m.span("手机→Mac 对会话说·全程（写下→已送达）", req, done)


def scene_send(run, args):
    """M3 发消息：send [轮数=10] [间隔秒=10]。"""
    rounds, gap = int(args[0]) if args else 10, float(args[1]) if len(args) > 1 else 10
    m = Metrics()
    for i in range(rounds):
        began = time.time()
        round_trip(run, i, m)
        time.sleep(max(0, began + gap - time.time()))
    return m, {}


def writes(inst, commands, count, author):
    """给 inst 几条命令，等它写下 count 句（author 说的），再等都被服务器收下；返回写下的打点。"""
    t = time.time() - 0.5
    for c in commands: inst.send(c)
    got = []
    for _ in range(count):
        seen = {w["id"] for w in got}
        w = inst.wait(lambda e: kind("msg-write", author)(e) and e["id"] not in seen, 10, after=t)
        if w: got.append(w)
    for w in got: inst.wait(by_id("msg-sent" if author == "cue" else "msg-accepted", w["id"]), ROUND_LIMIT)
    return got


def cold_once(m, label, restarted, writer, writes):
    t0 = restarted.start()
    ready = restarted.wait(kind("ready"), 60, after=t0)
    got = [restarted.wait(arrived(w["id"]), ROUND_LIMIT, after=t0) for w in writes]
    shown = [restarted.wait(by_id("msg-shown", w["id"]), 30, after=t0) for w in writes]
    start = {"t": t0}
    m.span(f"{label}·启动→打点就绪", start, ready)
    m.span(f"{label}·启动→最后一条入库", start, max(got, key=lambda e: e["t"]) if all(got) else None)
    m.span(f"{label}·启动→最后一条上屏", start, max(shown, key=lambda e: e["t"]) if all(shown) else None)


def scene_cold(run, args):
    """M1 冷启动到内容最新：cold [条数=5] [次数=3]。手机（B）退出期间 Mac 的 Cue 说 N 句；Mac（A）退出期间手机对 Cue 说 N 句。"""
    count, times = int(args[0]) if args else 5, int(args[1]) if len(args) > 1 else 3
    m = Metrics()
    for _ in range(times):
        run.b.stop()
        cold_once(m, "手机冷启动", run.b, run.a, writes(run.a, [f"cue {count}"], count, "cue"))
        time.sleep(5)
        run.a.stop()
        cold_once(m, "Mac 冷启动", run.a, run.b, writes(run.b, [f"say cold{i}" for i in range(count)], count, "you"))
        time.sleep(10)
    return m, {}


def scene_fg(run, args):
    """M2 回前台到内容最新：fg [次数=5] [离开秒=15]。手机进后台（停拉、断门铃）期间 Mac 的 Cue 说一句；Mac 隐藏期间手机对 Cue 说一句。"""
    times, away = int(args[0]) if args else 5, float(args[1]) if len(args) > 1 else 15
    a, b = run.a, run.b
    m = Metrics()
    for _ in range(times):
        t = b.send("bg"); b.wait(kind("bg-done"), 30, after=t)
        w = writes(a, ["cue 1"], 1, "cue")
        time.sleep(away)
        if w:
            id = w[0]["id"]
            before = b.first("msg-arrived", id)
            t0 = {"t": b.send("fg")}
            if before: m["手机回前台·离开期间已到（次）"].append(1)
            m.span("手机回前台·回前台→入库", t0, before or b.wait(arrived(id), ROUND_LIMIT, after=t0["t"]))
            m.span("手机回前台·回前台→上屏", t0, b.wait(by_id("msg-shown", id), ROUND_LIMIT))
        else:
            b.send("fg")
        time.sleep(5)
        a.send("hide")
        w = writes(b, ["say fg"], 1, "you")
        time.sleep(away)
        if w:
            id = w[0]["id"]
            m.span("Mac 隐藏·已发出→Mac 入库", b.first("msg-accepted", id), a.wait(arrived(id), 1))
            early = a.first("msg-shown", id)
            t0 = {"t": a.send("activate")}
            if early: m["Mac 隐藏期间已上屏（次）"].append(1)
            else: m.span("Mac 回前台·回前台→上屏", t0, a.wait(by_id("msg-shown", id), ROUND_LIMIT))
        else:
            a.send("activate")
        time.sleep(5)
    return m, {}


def scene_idle(run, args):
    """M6 常驻开销：idle [分钟=10] [每轮秒=30]。窗口里 B 每轮做一次 send 场景的一轮再立即同步一次；记两端的 CloudKit 操作与进程开销。"""
    minutes, every = float(args[0]) if args else 10, float(args[1]) if len(args) > 1 else 30
    pids = {"A": run.a.pid, "B": run.b.pid}
    window = f"{run.out}/window.log"
    predicate = f"({' OR '.join(f'processID == {p}' for p in pids.values())}) AND subsystem BEGINSWITH \"com.apple.cloudkit\""
    stream = subprocess.Popen(["log", "stream", "--info", "--debug", "--style", "compact", "--predicate", predicate],
                              stdout=open(window, "w"), stderr=subprocess.DEVNULL)
    m = Metrics()
    start, before = time.time(), {r: usage(p) for r, p in pids.items()}
    i = 0
    while time.time() < start + minutes * 60:
        began = time.time()
        round_trip(run, f"idle{i}", m)
        t = run.b.send("sync")
        synced = run.b.wait(kind("sync-now"), 30, after=t)
        if synced: m["立即同步·拉完"].append(round(synced["took"], 3))
        i += 1
        time.sleep(max(0, began + every - time.time()))
    after, end = {r: usage(p) for r, p in pids.items()}, time.time()
    stream.terminate(); stream.wait()
    hours = (end - start) / 3600
    extra = {}
    for role, pid in pids.items():
        d = lambda k: after[role][k] - before[role][k]
        ops, up, down = cloudkit_ops(window, pid)
        extra[role] = {"CloudKit 操作/时": round(sum(ops.values()) / hours), "上传 KB/时": round(sum(up.values()) / hours / 1e3),
                       "下载 KB/时": round(sum(down.values()) / hours / 1e3), "指令 G/时": round(d("instructions") / hours / 1e9, 2),
                       "CPU 秒/时": round((d("user") + d("system")) * NS / 1e9 / hours, 1),
                       "唤醒/秒": round((d("idle_wkups") + d("interrupt_wkups")) / (end - start), 2),
                       "能耗 J/时": round(d("energy_nj") / 1e9 / hours, 1), "内存 MB": round(after[role]["footprint"] / 2**20),
                       "操作明细": {f"{k[0]} {k[1]}": round(n / hours) for k, n in ops.most_common()}}
    return m, extra


def cloudkit_ops(window, pid):
    """窗口内 pid 的 CloudKit 操作次数与字节（debug 级的 CKOperationMetrics，不落盘，所以边跑边收）。"""
    ops, up, down = Counter(), Counter(), Counter()
    for l in open(window, errors="ignore"):
        hit = re.search(rf"\[{pid}:.*Operation was marked as finished: <(CK\w+): .*bytesUploaded=(\d+), bytesDownloaded=(\d+)", l)
        if not hit or hit.group(1) == "CKPlaceholderOperation": continue
        group = re.search(r"(?:full|shortened)-name=([^ ,}]+)", l)
        key = (hit.group(1), group.group(1) if group else "（无组）")
        ops[key] += 1; up[key] += int(hit.group(2)); down[key] += int(hit.group(3))
    return ops, up, down


SCENES = {"send": scene_send, "cold": scene_cold, "fg": scene_fg, "idle": scene_idle}
