#!/usr/bin/env python3
"""同步测量（CloudKit 开发环境）：同一台 Mac 上开两个隔离实例经 iCloud 同步，跑固定时长，按 PID 统计 CloudKit 操作（次数与字节，取自 CKOperationMetrics）与时延。
A 是"有在线会话的 Mac"：这里起一个说桥协议的假扩展，几个会话不停切状态，收到的话一律受理；
B 代替开着 Agent 页的手机（模拟器登不了 iCloud；拉取节奏按手机那档）：每轮给 A 的一个会话"马上说"一句、对 Cue 说一句、立即同步一次（打点见 DebugScene+SyncBench.swift）。

用法：sync-bench.py [分钟=10]
构建是本检出 apple/.derived 里开发环境签名的那份（CUEPAD_SIGN=development xc.sh build mac）；库、日志在 /tmp/sync-bench。
两个实例同时开是这里独有的，不经 app.py 的全机一份；隔离目录同样取 app.isolated_env。
环境：SYNC_BENCH_SESSIONS 会话数（默认 3）；
      SYNC_BENCH_FLIP 每个会话平均几秒切一次状态（默认 8）；SYNC_BENCH_EVERY B 每轮间隔秒（默认 30）；SYNC_BENCH_WARMUP 预热秒（默认 90，不计入）。
前提、口径与限制见 docs/verify.md「同步测量」。只结束自己起的进程。
"""
import json, os, random, re, select, socket, statistics, subprocess, sys, time
from collections import Counter
from datetime import datetime

sys.dont_write_bytecode = True
from app import isolated_env  # noqa: E402

APPLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SESSIONS = int(os.environ.get("SYNC_BENCH_SESSIONS", 3))
FLIP = float(os.environ.get("SYNC_BENCH_FLIP", 8))
EVERY = int(os.environ.get("SYNC_BENCH_EVERY", 30))
WARMUP = int(os.environ.get("SYNC_BENCH_WARMUP", 90))
EXE = f"{APPLE}/.derived/Build/Products/Debug/CuePad.app/Contents/MacOS/CuePad"
BENCH = "/tmp/sync-bench"
STATES = [{"kind": "thinking"}, {"kind": "tool", "tool": "bash", "tools": ["bash"], "detail": "pnpm test"},
          {"kind": "outputting"}, {"kind": "done", "aborted": False}, {"kind": "idle"}]


def extension_version():
    source = open(f"{APPLE}/CuePadKit/Sources/CuePi/Extension/cuepad-bridge.ts").read()
    return int(re.search(r"const EXTENSION_VERSION = (\d+);", source).group(1)), int(re.search(r"const PROTOCOL_VERSION = (\d+);", source).group(1))


def fake_extension(directory):
    """假扩展（子进程里跑）：SESSIONS 个会话，各自按指数分布的间隔切状态；任何带 id 的命令都回 ack ok。"""
    version, protocol = extension_version()
    os.makedirs(directory, mode=0o700, exist_ok=True); os.chmod(directory, 0o700)
    now = lambda: time.time() * 1000
    sessions = []
    for i in range(SESSIONS):
        sid = f"sync-bench-{i}"
        path = f"{directory}/{sid}.{os.getpid()}.sock"
        if os.path.exists(path): os.remove(path)
        s = socket.socket(socket.AF_UNIX); s.bind(path); os.chmod(path, 0o600); s.listen(4); s.setblocking(False)
        sessions.append({"id": sid, "path": path, "server": s, "clients": [], "state": {"kind": "idle", "since": now()},
                         "next": time.time() + random.expovariate(1 / FLIP)})
    def send(c, msg):
        try: c.sendall((json.dumps(msg) + "\n").encode())
        except OSError: pass
    def hello(s):
        return {"t": "hello", "protocol": protocol, "extensionVersion": version, "sessionId": s["id"], "sessionFile": None, "pid": os.getpid(),
                "cwd": "/tmp", "mode": "tui", "tty": None, "term": {}, "state": s["state"], "name": s["id"], "firstMessage": None}
    running = True
    def stop(*_):
        nonlocal running; running = False
    import signal; signal.signal(signal.SIGTERM, stop)
    while running:
        readable = [s["server"] for s in sessions] + [c for s in sessions for c in s["clients"]]
        ready, _, _ = select.select(readable, [], [], 0.2)
        for s in sessions:
            if s["server"] in ready:
                c, _ = s["server"].accept(); s["clients"].append(c); send(c, hello(s))
            for c in list(s["clients"]):
                if c not in ready: continue
                data = c.recv(65536)
                if not data: s["clients"].remove(c); continue
                for line in data.decode(errors="ignore").splitlines():
                    try: msg = json.loads(line)
                    except ValueError: continue
                    if "id" in msg: send(c, {"t": "ack", "id": msg["id"], "ok": True, "delivered": "steer"})
            if time.time() >= s["next"]:
                state = dict(random.choice(STATES)); state["since"] = now()
                busy = state["kind"] not in ("idle", "done")
                state["busySince"] = s["state"].get("busySince") or now() if busy else None
                s["state"] = state; s["next"] = time.time() + random.expovariate(1 / FLIP)
                for c in s["clients"]: send(c, {"t": "state", "state": state})
    for s in sessions:  # 正常收尾：会话以"结束"同步出去，下次跑不会被当成在线的会话
        for c in s["clients"]: send(c, {"t": "bye", "reason": "quit"}); c.close()
        s["server"].close(); os.remove(s["path"])


def launch(role, socket_dir):
    home = f"{BENCH}/{role}"
    env = dict(isolated_env(f"{home}/library", socket_dir), CUEPAD_SHOT_READY=f"{home}/ready")
    args = [EXE, "-CuePadCloudKit", "YES", "-CuePadHost", f"bench-{role}", "-CuePadSyncBench", "host" if role == "a" else "remote",
            "-CuePadSyncBenchEvery", str(EVERY), "-CuePadOffscreen", "YES"]
    return subprocess.Popen(args, env=env, stdout=open(f"{home}.log", "w"), stderr=subprocess.STDOUT)


def stamp(t): return datetime.fromtimestamp(t).strftime("%Y-%m-%d %H:%M:%S")


def summarize(values):
    if not values: return "—"
    values = sorted(values)
    p90 = values[min(len(values) - 1, int(len(values) * 0.9))]
    return f"n={len(values)} 中位 {statistics.median(values):.2f} p90 {p90:.2f} 最大 {values[-1]:.2f}"


def stream(pids):
    """窗口内两个实例的 CloudKit 与 CuePad 日志。操作的字节数只在 debug 级的"marked as finished"里（CKOperationMetrics），
    不落盘，log show 事后取不到，所以边跑边收。"""
    predicate = f"({' OR '.join(f'processID == {p}' for p in pids)}) AND (subsystem BEGINSWITH \"com.apple.cloudkit\" OR subsystem == \"com.sugeh.cuepad\")"
    return subprocess.Popen(["log", "stream", "--info", "--debug", "--style", "compact", "--predicate", predicate],
                            stdout=open(f"{BENCH}/window.log", "w"), stderr=subprocess.DEVNULL)


def report(pids, start, end):
    hours = (end - start) / 3600
    log = open(f"{BENCH}/window.log").read()
    print(f"\n窗口 {stamp(start)} → {stamp(end)}（{(end - start) / 60:.1f} 分钟），会话 {SESSIONS} 个、平均 {FLIP:g} 秒切一次状态，B 每 {EVERY} 秒一轮")
    for role, pid in pids.items():
        ops, up, down, took, queued = Counter(), Counter(), Counter(), [], []
        for l in log.splitlines():
            m = re.search(rf"\[{pid}:.*Operation was marked as finished: <(CK\w+): .*bytesUploaded=(\d+), bytesDownloaded=(\d+)", l)
            if not m or m.group(1) == "CKPlaceholderOperation": continue
            timing = re.search(r"duration=([\d.]+), queueing=([\d.]+)", l)
            if timing: took.append(float(timing.group(1))); queued.append(float(timing.group(2)))
            group = re.search(r"(?:full|shortened)-name=([^ ,}]+)", l)
            key = (m.group(1), group.group(1) if group else "（无组）")
            ops[key] += 1; up[key] += int(m.group(2)); down[key] += int(m.group(3))
        total = sum(ops.values())
        print(f"\n{'A 有会话的 Mac' if role == 'a' else 'B 代替手机'}（PID {pid}）：CloudKit 操作 {total / hours:.0f} 次/小时；"
              f"上传 {sum(up.values()) / hours / 1e6:.2f} MB/小时、下载 {sum(down.values()) / hours / 1e6:.2f} MB/小时")
        print(f"  每个操作用时 {summarize(took)}；其中排队 {summarize(queued)}")
        for key, n in ops.most_common():
            print(f"  {n / hours:7.0f} 次/时  上 {up[key] / hours / 1e3:7.0f} KB/时  下 {down[key] / hours / 1e3:7.0f} KB/时  {key[0]:<36} {key[1]}")
    bench = [l.split("[com.sugeh.cuepad:bench] ", 1)[1] for l in log.splitlines() if "[com.sugeh.cuepad:bench] " in l]
    def values(event, key):
        return [float(m.group(1)) for l in bench if l.startswith(event + " ") for m in [re.search(rf"\b{key}=(-?[\d.]+)", l)] if m]
    print("\n时延（秒）")
    for label, event, key in [("B 发出 → B 看到结果（往返）", "send", "total"), ("  其中 B 立即上传", "send", "upload"),
                              ("  其中 上传完 → A 执行完（跨进程时钟同机）", "send", "toMac"), ("  其中 A 执行完 → B 看到", "send", "back"),
                              ("B 对 Cue 说 → 到 A 的库", "cue-arrived", "lag"), ("B 立即同步（syncNow）", "syncNow", "took")]:
        print(f"  {label:<36} {summarize(values(event, key))}")
    failures = [l for l in bench if "failed=true" in l or "bench-error" in l]
    if failures: print(f"  失败 {len(failures)} 条，见 {BENCH}/window.log")


def main(minutes):
    if not os.path.exists(EXE) or os.environ.get("SYNC_BENCH_SKIP_BUILD") != "1":
        subprocess.run([f"{APPLE}/scripts/xc.sh", "build", "mac"], env=dict(os.environ, CUEPAD_SIGN="development"), check=True)
    subprocess.run(["rm", "-rf", BENCH]); os.makedirs(BENCH)
    socket_a, socket_b = f"/tmp/cpsb-a-{os.getuid()}", f"/tmp/cpsb-b-{os.getuid()}"
    os.makedirs(socket_b, mode=0o700, exist_ok=True); os.chmod(socket_b, 0o700)
    extension = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--fake-extension", socket_a])
    a = launch("a", socket_a); time.sleep(5); b = launch("b", socket_b)
    pids = {"a": a.pid, "b": b.pid}
    print(f"A={a.pid} B={b.pid} 假扩展={extension.pid}；预热 {WARMUP} 秒")
    try:
        time.sleep(WARMUP)
        for p in (a, b):
            if p.poll() is not None: raise SystemExit(f"实例 {p.pid} 已退出（日志 {BENCH}/*.log）")
        log = stream(pids.values()); start = time.time()
        time.sleep(minutes * 60)
        end = time.time(); log.terminate(); log.wait()
    finally:
        extension.terminate(); extension.wait()
        time.sleep(5)  # A 把会话结束同步出去
        for p in (b, a):
            p.terminate()
            try: p.wait(10)
            except subprocess.TimeoutExpired: p.kill()
    report(pids, start, end)


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--fake-extension":
        fake_extension(sys.argv[2])
    else:
        main(float(sys.argv[1]) if len(sys.argv) > 1 else 10)
