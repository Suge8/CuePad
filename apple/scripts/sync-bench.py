#!/usr/bin/env python3
"""同步体验测量：同一台 Mac 上开两个隔离实例互相同步——A 是有在线会话、Cue 在值班的 Mac（会话由假扩展给，Cue 的大脑是回"知道了。"的替身），
B 代替手机（模拟器登不了 iCloud；拉取节奏按手机那档，进后台、回前台走手机的那两个入口）。
两端只听这里经标准输入给的命令、在标准输出打点（DebugScene+SyncBench.swift），这里按事件驱动、按记录 id 把两端的打点拼成每一段的用时。

云有两种（SYNC_BENCH_CLOUD）：
  sim（默认）两个实例共用这次运行自己的模拟云（SharedCloud：一个 SQLite 文件，同步代码照真的跑），每个请求按 LATENCY 睡一段；门铃照常连正式中转（房间按这次运行的密钥）。
      测的是我们自己代码的调度与排队，不连 iCloud、不吃也不制造设备限流。A/B 一律用它。
  real      连 CloudKit 开发环境，只做少量确认：限流按设备与容器算，与这台的正式版共用一份（实测见 docs/perf.md「真 CloudKit」）。
      所以：上一次 real 运行结束不满 REAL_COOLDOWN 秒、或最近 5 分钟这台有 429，就不跑（ab 里两次之间等冷却）；每次运行连预热至多 REAL_LIMIT 秒，
      到点收掉实例、已量到的照记；每个实例至多 REAL_BUDGET 个请求，用满当断网、不再打 iCloud。库留在 REAL_LIBS 里接着用，不每次从头拉开发区的历史。
LATENCY（中位、p95，秒，对数正态；版本 MODEL）：每种请求在 App 里从发起到返回的用时（`CloudOutage` 在真 CloudKit 运行里记下，`request_timings`，结果里的"请求用时"）。
  v2 出处：2026-10-26 07:25 真 CloudKit 运行（send 15 9，负载 628，429 为 0，A、B 两个进程）：上传 n=154 0.449 / 0.984；拉取 n=175 0.192 / 0.620；
  按 ID 取记录 n=2 0.197 / 0.752；账号、密钥、建区 n=6 0.068 / 0.469。
  标定时查过"App 到 cloudd 的开销与排队"：同一次运行里 CloudKit 自己记的 Starting→Finished（default 级日志，按 operationID 配对）是上传 0.451 / 0.984、拉取 0.198 / 0.620，
  与 App 里量到的几乎一样，这一截可以忽略。v1（10-24 research/sync-measure，load1 中位约 16：上传 0.234 / 0.513、拉取 0.133 / 0.410）比真环境每经过一次云少约 0.2 秒，
  是那天的请求本身快；10-26 几次真运行之间每种请求的中位也差 20–30%（上传 0.35–0.45），这是模型自带的误差，所以用最近一次、样本最多的那次。
  v3 加文件的传输速率（字节/秒，请求本身的用时照上）：上行 3.7 MB/s、下行 37 MB/s，出处是 2026-10-27 研究分支 research/asset-probe 在开发环境传取
  100–500MB 的单个资产（这台 Mac 当时 networkQuality 上行 50 Mbps、下行 408 Mbps）：上传扣掉第一个进度回调前的 1.1–1.6 秒是 3.6–4.0 MB/s，
  取 100MB 扣掉 1 秒是 37 MB/s。手机的上行多半更慢，看前后差，不看绝对值。
  不含：改记录冲突、限流。改动这里就是换了模拟云的口径：前后对比两边同一版（结果里记着 model）。

用法：
  sync-bench.py <场景> [参数…]                              本检出：构建开发签名的 Debug，跑一次
  sync-bench.py ab <检出X> <检出Y> <轮数> <场景> [参数…]      两个检出各构建一次，按 X Y、Y X… 交替跑 <轮数> 轮，出对比表
场景（实现与每段的定义在 _sync_scenes.py，断网、限流、进后台收尾与撞版本在 _sync_edges.py）：
  send [轮数=10] [间隔=10]   M3 发消息：手机对 Cue 说（写下→已发出→Mac 入库→上屏→交给 Cue→回执）、对会话说（→执行完→结果回来）、Cue 回话到手机（→入库→上屏）
  cold [条数=5] [次数=3]     M1 冷启动：一端退出期间另一端写 N 句，从进程启动到最后一句入库、上屏（手机、Mac 各一遍）
  fg [次数=5] [离开秒=15]    M2 回前台：手机进后台期间、Mac 隐藏期间对端写一句，从回前台到入库、上屏
  idle [分钟=10] [每轮秒=30] M6 常驻开销：每轮一次 send 加立即同步，记两端的请求数、指令、CPU、唤醒、能耗（real 另记 CloudKit 字节）
  offline [秒=30] [次数=2] [path|nopath]  M5 断网恢复：只让手机的请求以 -1009 失败、门铃断开，断着时两边各写 3 句；恢复到第一次成功、积压发完、收完、回执
  throttle [限流秒=20] [Retry-After=8] [次数=2]  M7 限流（只在模拟云）：窗口内云按设备限流回 429；数各实例窗口内的拉取、上传与早于 Retry-After 的请求，解除到第一拉成功
  bgflush [次数=8]           M8 写完马上进后台：写下→已发出、进后台→收尾完、写下→Mac 入库
  versions [命令行改几次=150] 撞版本探针（不进总表）：App 紧循环改一张卡、命令行同时逐条改，数提交后版本不比上一版大的次数
  files [轮数=6] [MB=50]     M9 带文件：手机同一刻写下带大文件的灵感、只有字的灵感、对 Cue 说的一句，Mac 收；量前两样与文件各自写下→Mac 入库（_sync_files.py）
  filesquota [轮数=2] [MB=50] 空间满（只在模拟云）：同上，文件被拒；量只有字的与对 Cue 说的照常到、手机状态不变、文件停着
  island [轮数=10]           M4 收消息到灵动岛（iPhone 模拟器，App 这一侧：入库→实时活动换内容）；不连云、不拿测量锁，xc.sh run ios 自己构建
环境：SYNC_BENCH_CLOUD=sim|real；SYNC_BENCH_RELAY=0 两端都不连门铃（门铃不通，只靠按节奏拉）；SYNC_BENCH_SKIP_BUILD=1 不构建；
  SYNC_BENCH_SESSIONS 会话数（默认 3）、SYNC_BENCH_FLIP 会话平均几秒切一次状态（默认 8）；SYNC_BENCH_WARM 预热上限秒（默认 300）；SYNC_BENCH_LOCK_WAIT 等锁上限秒（默认 1200，到点列出持有者、以 75 退出）。
每次跑之前拿全机测量锁（flock，进程退出就放；持有者写在锁文件里）：real 拿 LOCK（与别的连 CloudKit 的探针共用，不同时用 cloudd），
sim 拿 SIM_LOCK（几个模拟云运行不同时抢 CPU；不碰 cloudd，不必等 real）；构建在锁外。
结果在 OUT_ROOT/<时刻>-<场景>/：a.log、b.log（实例的全部输出）、result.json（每个指标的样本、负载、构建、云）；对比的汇总在 ab-*.json。
口径与限制见 docs/perf.md「同步测量」。只结束自己起的进程。
"""
import fcntl, json, os, signal, subprocess, sys, time
from datetime import datetime

sys.dont_write_bytecode = True
from _sync_run import OUT_ROOT, Aborted, Load, Run, exe_of, fake_extension  # noqa: E402
from _sync_edges import EDGES  # noqa: E402
from _sync_files import SCENES as FILES  # noqa: E402
from _sync_scenes import SCENES as BASIC, island  # noqa: E402
from app_env import BUNDLE_ID, CHECKOUT  # noqa: E402

LOCK = "/tmp/cuepad-sync-measure.lock"  # real 与别的连 CloudKit 的探针共用
SIM_LOCK = "/tmp/cuepad-sync-measure-sim.lock"  # 模拟云的运行之间互斥（不碰 cloudd，不必等 real）
RELAY = os.environ.get("SYNC_BENCH_RELAY", "1") != "0"
CLOUD = os.environ.get("SYNC_BENCH_CLOUD", "sim")
MODEL = "v3"
LATENCY = {"upload": [0.449, 0.984], "fetch": [0.192, 0.620], "records": [0.197, 0.752], "other": [0.068, 0.469],
           "assetUp": 3.7e6, "assetDown": 37e6}  # 出处见头注释
REAL_COOLDOWN, REAL_LIMIT, REAL_BUDGET = 600, 180, 200
REAL_LAST = "/tmp/cuepad-sync-measure.last-real"  # 上一次 real 运行结束的时刻
SCENES = BASIC | EDGES | FILES


LOCK_EXIT = 75  # 等锁超时的退出码，同 xc.sh 的入口锁（_lock.sh）


def hold_lock(what):
    """拿测量锁（flock 阻塞等，排队先后由内核定），返回打开的锁文件：进程活着就一直持有。等的时候每分钟列一次持有者与它已经占了多久；
    等满 SYNC_BENCH_LOCK_WAIT 秒（默认 1200）还没轮到，列出持有者、以 LOCK_EXIT 退出，不一直挂着。"""
    f = open(LOCK if CLOUD == "real" else SIM_LOCK, "a+")
    limit = float(os.environ.get("SYNC_BENCH_LOCK_WAIT", 1200))
    began = time.time()
    def holder():
        f.seek(0)
        try: h = json.loads(f.read())
        except ValueError: return "（锁文件里没有登记）"
        held = time.time() - datetime.fromisoformat(h["since"]).timestamp()
        return f"PID {h['pid']}（{h['checkout']}）{h['what']}，已占 {int(held) // 60} 分 {int(held) % 60:02d} 秒"
    def tick(*_):
        waited = time.time() - began
        if waited >= limit:
            print(f"等测量锁 {int(waited)} 秒没轮到，以 {LOCK_EXIT} 退出。持有者：{holder()}", file=sys.stderr, flush=True)
            os._exit(LOCK_EXIT)
        print(f"排队等测量锁（已等 {int(waited) // 60} 分 {int(waited) % 60:02d} 秒），持有者：{holder()}", flush=True)
        signal.setitimer(signal.ITIMER_REAL, min(60, limit - waited))
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        signal.signal(signal.SIGALRM, tick)
        tick()
        try: fcntl.flock(f, fcntl.LOCK_EX)
        finally: signal.setitimer(signal.ITIMER_REAL, 0)
    f.seek(0); f.truncate()
    f.write(json.dumps({"pid": os.getpid(), "checkout": CHECKOUT, "what": what, "since": datetime.now().isoformat(timespec="seconds")}, ensure_ascii=False))
    f.flush()
    return f


def throttled(minutes=2, pids=None):
    """最近几分钟这台 Mac 上 CuePad 收到的 CloudKit 限流次数（`Request Rate Limited`、`Device throttle`：按设备与容器算，正式版与测量实例共用一份）；
    pids 给了只数这几个进程。只认 CloudKit 的限流错误：日志里别的数字（"用时 0.00042925 秒"）含 429 也不是限流。"""
    who = f" AND ({' OR '.join(f'processID == {p}' for p in pids)})" if pids else ""
    predicate = f'subsystem == "{BUNDLE_ID}" AND (eventMessage CONTAINS "{THROTTLE_MARKS[0]}" OR eventMessage CONTAINS "{THROTTLE_MARKS[1]}"){who}'
    out = subprocess.run(["log", "show", "--last", f"{minutes}m", "--predicate", predicate], capture_output=True, text=True).stdout
    return sum(1 for l in out.splitlines() if any(mark in l for mark in THROTTLE_MARKS))


THROTTLE_MARKS = ("Request Rate Limited", "Device throttle")


def real_allowed(wait):
    """real 运行的冷却：上一次结束满 REAL_COOLDOWN 秒、最近 5 分钟这台没有 429 才跑。wait 时（ab 的两次之间）等冷却过去，否则拒跑。"""
    last = float(open(REAL_LAST).read()) if os.path.exists(REAL_LAST) else 0
    left = last + REAL_COOLDOWN - time.time()
    if left > 0:
        if not wait: raise SystemExit(f"上一次真 CloudKit 运行结束才 {(REAL_COOLDOWN - left) / 60:.1f} 分钟，满 {REAL_COOLDOWN // 60} 分钟再跑")
        print(f"  等真 CloudKit 的冷却 {left:.0f} 秒", flush=True)
        time.sleep(left)
    n = throttled(minutes=5)
    if n: raise SystemExit(f"这台 Mac 最近 5 分钟被 CloudKit 限流 {n} 次（正式版与测量共用一份设备限流），不跑；等没有 429 再测")


def build(checkout):
    if os.environ.get("SYNC_BENCH_SKIP_BUILD") == "1" and os.path.exists(exe_of(checkout)): return
    subprocess.run([f"{checkout}/apple/scripts/xc.sh", "build", "mac"], env=dict(os.environ, CUEPAD_SIGN="development"), check=True)


def commit(checkout):
    head = subprocess.run(["git", "-C", checkout, "log", "-1", "--format=%h %s"], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run(["git", "-C", checkout, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True).stdout.strip()
    return head[:60] + ("（有未提交改动）" if dirty else "")


def run_once(checkout, scene, args, label="", wait=False):
    out = f"{OUT_ROOT}/{datetime.now():%m%d-%H%M%S}-{scene}{'-' + label if label else ''}"
    cloud = f"模拟云（延迟模型 {MODEL}）" if CLOUD == "sim" else "真 CloudKit（开发环境）"
    print(f"\n== {scene} {' '.join(args)}：{checkout}（{commit(checkout)}），{cloud}，门铃{'通' if RELAY else '不通'}；输出 {out}", flush=True)
    real = CLOUD == "real" and scene != "island"
    if real: real_allowed(wait)
    load, extra = Load(), {}
    if scene == "island":
        metrics, extra = island(checkout, out, args)
    else:
        began = time.time()
        run = Run(checkout, out, RELAY, CLOUD, latency=LATENCY, budget=REAL_BUDGET, limit=REAL_LIMIT if real else None)
        try:
            with run:
                metrics, extra = SCENES[scene](run, args)
                extra["请求用时"] = request_timings(run)
        except Aborted as stopped:
            print(f"  中止：{stopped}", flush=True)
        finally:
            if real: open(REAL_LAST, "w").write(str(time.time()))
        metrics = run.metrics
        if real:
            hit = throttled(minutes=int((time.time() - began) / 60) + 1, pids=[i.pid for i in (run.a, run.b) if i.proc])
            extra["限流"] = {"窗口内 429 次数": hit}
            if hit: print(f"  这次运行期间实例被 CloudKit 限流 {hit} 次：时延里含限流的等待，作废重测", flush=True)
    result = {"scene": scene, "args": args, "checkout": checkout, "commit": commit(checkout), "relay": RELAY, "cloud": CLOUD, "model": MODEL if CLOUD == "sim" else None,
              "load": load.summary(), "metrics": dict(metrics), "extra": extra}
    json.dump(result, open(f"{out}/result.json", "w"), ensure_ascii=False, indent=1)
    return result


def request_timings(run):
    """两个实例每种请求在 App 里从发起到返回的用时（中位、p95、次数）：真 CloudKit 运行据此标定模拟云的 LATENCY。"""
    found = {}
    for inst in (run.a, run.b):
        if not inst.alive(): continue
        t = inst.send("stats")
        e = inst.wait(lambda e: e["e"] == "stats" and "timings" in e, 10, after=t)
        for kind, values in (e or {}).get("timings", {}).items(): found.setdefault(kind, []).extend(values)
    return {k: [round(pct(v, 0.5), 3), round(pct(v, 0.95), 3), len(v)] for k, v in found.items() if v}


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
        hits = sum(r["extra"].get("限流", {}).get("窗口内 429 次数", 0) for r in results)
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
                results[label].append(run_once(sides[label], scene, args, label, wait=True))
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
