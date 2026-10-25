#!/usr/bin/env python3
"""同步体验测量（CloudKit 开发环境）：同一台 Mac 上开两个隔离实例经 iCloud 同步——A 是有在线会话、Cue 在值班的 Mac（会话由假扩展给，
Cue 的大脑是回"知道了。"的替身），B 代替手机（模拟器登不了 iCloud；拉取节奏按手机那档，进后台、回前台走手机的那两个入口）。
两端只听这里经标准输入给的命令、在标准输出打点（DebugScene+SyncBench.swift），这里按事件驱动、按记录 id 把两端的打点拼成每一段的用时。

用法：
  sync-bench.py <场景> [参数…]                              本检出：构建开发签名的 Debug，跑一次
  sync-bench.py ab <检出X> <检出Y> <轮数> <场景> [参数…]      两个检出各构建一次，按 X Y、Y X… 交替跑 <轮数> 轮，出对比表
场景（实现与每段的定义在 _sync_scenes.py）：
  send [轮数=10] [间隔=10]   M3 发消息：手机对 Cue 说（写下→已发出→Mac 入库→上屏→交给 Cue→回执）、对会话说（→执行完→结果回来）、Cue 回话到手机（→入库→上屏）
  cold [条数=5] [次数=3]     M1 冷启动：一端退出期间另一端写 N 句，从进程启动到最后一句入库、上屏（手机、Mac 各一遍）
  fg [次数=5] [离开秒=15]    M2 回前台：手机进后台期间、Mac 隐藏期间对端写一句，从回前台到入库、上屏
  idle [分钟=10] [每轮秒=30] M6 常驻开销：每轮一次 send 加立即同步，记两端的 CloudKit 操作、字节、指令、CPU、唤醒、能耗
  offline [秒=30] [次数=2] [path|nopath]  M5 断网恢复：只让手机的 iCloud 请求以 -1009 失败、门铃断开，断着时两边各写 3 句；恢复到第一次成功、积压发完、收完、回执
  island [轮数=10]           M4 收消息到灵动岛（iPhone 模拟器，App 这一侧：入库→实时活动换内容）；不连 iCloud、不拿测量锁，xc.sh run ios 自己构建
环境：SYNC_BENCH_RELAY=0 两端都不连门铃（门铃不通，只靠按节奏拉）；SYNC_BENCH_SKIP_BUILD=1 不构建；SYNC_BENCH_SESSIONS 会话数（默认 3）、
  SYNC_BENCH_FLIP 会话平均几秒切一次状态（默认 8）；SYNC_BENCH_WARM 预热上限秒（默认 300）；SYNC_BENCH_LOCK_WAIT 等锁上限秒（默认 3600）。
每次跑之前查这台最近 2 分钟有没有被 CloudKit 限流（`throttled`：限流按设备与容器算，测量实例与正式版共用一份），被限着就不跑；
运行期间被限流的次数记进结果并在报告里标出。每次跑之前拿全机测量锁 LOCK（flock，进程退出就放；持有者写在锁文件里），几个检出的测量不同时跑、不共用 cloudd 互相干扰；构建在锁外。
结果在 OUT_ROOT/<时刻>-<场景>/：a.log、b.log（实例的全部输出）、result.json（每个指标的样本、负载、构建）；对比的汇总在 ab.json。
口径与限制见 docs/perf.md「同步测量」。只结束自己起的进程。
"""
import fcntl, json, os, signal, subprocess, sys, time
from datetime import datetime

sys.dont_write_bytecode = True
from _sync_run import Load, Run, exe_of, fake_extension  # noqa: E402
from _sync_scenes import SCENES, island  # noqa: E402
from app_env import BUNDLE_ID  # noqa: E402

CHECKOUT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LOCK = "/tmp/cuepad-sync-measure.lock"
OUT_ROOT = "/tmp/cuepad-sync-bench"
RELAY = os.environ.get("SYNC_BENCH_RELAY", "1") != "0"


def hold_lock(what):
    """拿全机测量锁（flock 阻塞等，排队先后由内核定；每分钟打印一次持有者，最多 SYNC_BENCH_LOCK_WAIT 秒），返回打开的锁文件：进程活着就一直持有。"""
    f = open(LOCK, "a+")
    limit = float(os.environ.get("SYNC_BENCH_LOCK_WAIT", 3600))
    def holder(*_):
        f.seek(0); return f.read().strip()
    def tick(*_):
        if time.time() - began > limit: raise SystemExit(f"等锁 {limit:.0f} 秒没轮到，持有者：{holder()}")
        print(f"排队等测量锁，持有者：{holder()}", flush=True)
    began = time.time()
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        tick()
        signal.signal(signal.SIGALRM, tick); signal.setitimer(signal.ITIMER_REAL, 60, 60)
        try: fcntl.flock(f, fcntl.LOCK_EX)
        finally: signal.setitimer(signal.ITIMER_REAL, 0)
    f.seek(0); f.truncate()
    f.write(json.dumps({"pid": os.getpid(), "checkout": CHECKOUT, "what": what, "since": datetime.now().isoformat(timespec="seconds")}, ensure_ascii=False))
    f.flush()
    return f


THROTTLE_LIMIT = 5  # 两分钟里这台的 CuePad 被 CloudKit 限流（429）超过这么多次就不跑


def throttled(minutes=2, pids=None):
    """最近几分钟这台 Mac 上 CuePad 收到的 CloudKit 限流（HTTP 429，`Device throttle`：按设备与容器算，正式版与测量实例共用一份）次数；
    pids 给了只数这几个进程。"""
    who = f" AND ({' OR '.join(f'processID == {p}' for p in pids)})" if pids else ""
    out = subprocess.run(["log", "show", "--last", f"{minutes}m", "--predicate", f'subsystem == "{BUNDLE_ID}" AND eventMessage CONTAINS "429"{who}'],
                         capture_output=True, text=True).stdout
    return sum(1 for l in out.splitlines() if "429" in l and not l.startswith("Timestamp"))


def refuse_if_throttled():
    """限流按设备算：测量实例把这台推进限流，正式版的同步也跟着被拒。被限着时不跑，等它退下来。"""
    n = throttled()
    if n > THROTTLE_LIMIT:
        raise SystemExit(f"这台 Mac 最近 2 分钟被 CloudKit 限流 {n} 次（正式版与测量共用一份设备限流），不跑；等它降下来再测（{THROTTLE_LIMIT} 次以内）")


def build(checkout):
    if os.environ.get("SYNC_BENCH_SKIP_BUILD") == "1" and os.path.exists(exe_of(checkout)): return
    subprocess.run([f"{checkout}/apple/scripts/xc.sh", "build", "mac"], env=dict(os.environ, CUEPAD_SIGN="development"), check=True)


def commit(checkout):
    head = subprocess.run(["git", "-C", checkout, "log", "-1", "--format=%h %s"], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", checkout, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True).stdout.strip()
    return head[:60] + ("（有未提交改动）" if dirty else "")


def run_once(checkout, scene, args, label=""):
    out = f"{OUT_ROOT}/{datetime.now():%m%d-%H%M%S}-{scene}{'-' + label if label else ''}"
    print(f"\n== {scene} {' '.join(args)}：{checkout}（{commit(checkout)}），门铃{'通' if RELAY else '不通'}；输出 {out}", flush=True)
    if scene != "island": refuse_if_throttled()
    load = Load()
    if scene == "island":
        metrics, extra = island(checkout, out, args)
    else:
        began = time.time()
        with Run(checkout, out, RELAY) as run:
            metrics, extra = SCENES[scene](run, args)
        hit = throttled(minutes=int((time.time() - began) / 60) + 1)
        extra["限流"] = {"窗口内 429 次数（含正式版）": hit}
        if hit: print(f"  这次运行期间这台被 CloudKit 限流 {hit} 次：时延里含限流的等待，前后对比作废重测", flush=True)
    result = {"scene": scene, "args": args, "checkout": checkout, "commit": commit(checkout), "relay": RELAY,
              "load": load.summary(), "metrics": dict(metrics), "extra": extra}
    json.dump(result, open(f"{out}/result.json", "w"), ensure_ascii=False, indent=1)
    return result


def pct(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def cell(values):
    return f"{pct(values, 0.5):6.2f} / {pct(values, 0.95):6.2f}  n={len(values):<3}" if values else "—"


def report(sides):
    """sides：[(名, [result…])]。每个指标一行 p50 / p95（秒）与样本数；超时、次数类的行是计数。"""
    names = []
    for _, results in sides:
        for r in results:
            names += [n for n in r["metrics"] if n not in names]
    merged = [{n: [v for r in results for v in r["metrics"].get(n, [])] for n in names} for _, results in sides]
    width = max(map(len, names), default=10) + 2
    print(f"\n{'指标（秒，p50 / p95）':<{width}}" + "".join(f"{name:<28}" for name, _ in sides) + ("Δp50" if len(sides) == 2 else ""))
    for n in names:
        counted = "（超时）" in n or "（次）" in n
        row = [f"{sum(m[n])} 次" if counted else cell(m[n]) for m in merged]
        delta = ""
        if len(sides) == 2 and not counted and all(m[n] for m in merged):
            x, y = (pct(m[n], 0.5) for m in merged)
            delta = f"{y - x:+.2f}（{(y - x) / x * 100:+.0f}%）" if x else f"{y - x:+.2f}"
        print(f"{n:<{width}}" + "".join(f"{c:<28}" for c in row) + delta)
    for name, results in sides:
        loads = [r["load"] for r in results]
        print(f"负载 {name}：1 分钟平均 {sum(l['mean'] for l in loads) / len(loads):.1f}（最高 {max(l['max'] for l in loads):.1f}，{loads[0]['cpus']} 核），{len(results)} 次运行")
        for r in results:
            for role, e in r["extra"].items():
                print(f"  {role}：" + "，".join(f"{k} {v}" for k, v in e.items() if k != "操作明细"))
        hits = sum(r["extra"].get("限流", {}).get("窗口内 429 次数（含正式版）", 0) for r in results)
        if hits: print(f"  ⚠ {name} 的运行期间共被限流 {hits} 次，这一边的数不可信")


def main(argv):
    if argv[:1] == ["ab"]:
        x, y, rounds, scene, args = os.path.abspath(argv[1]), os.path.abspath(argv[2]), int(argv[3]), argv[4], argv[5:]
        if scene not in SCENES and scene != "island": raise SystemExit(__doc__)
        if scene != "island": build(x); build(y)
        lock = hold_lock(f"ab {scene} {x} {y}") if scene != "island" else None  # noqa: F841 持有到进程结束
        sides, results = {"X": x, "Y": y}, {"X": [], "Y": []}
        for i in range(rounds):
            for label in ("X", "Y") if i % 2 == 0 else ("Y", "X"):
                results[label].append(run_once(sides[label], scene, args, label))
        os.makedirs(OUT_ROOT, exist_ok=True)
        json.dump(results, open(f"{OUT_ROOT}/ab-{datetime.now():%m%d-%H%M%S}-{scene}.json", "w"), ensure_ascii=False, indent=1)
        print(f"\nX = {x}（{commit(x)}）\nY = {y}（{commit(y)}）")
        report([(label, results[label]) for label in ("X", "Y")])
        return
    if not argv or argv[0] not in [*SCENES, "island"]: raise SystemExit(__doc__)
    if argv[0] != "island": build(CHECKOUT)
    lock = hold_lock(" ".join(argv)) if argv[0] != "island" else None  # noqa: F841
    report([(os.path.basename(CHECKOUT), [run_once(CHECKOUT, argv[0], argv[1:])])])


if __name__ == "__main__":
    if sys.argv[1:2] == ["--fake-extension"]:
        fake_extension(sys.argv[2], sys.argv[3])
    else:
        main(sys.argv[1:])
