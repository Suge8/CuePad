"""sync-bench.py 的实例与一次运行：两个隔离实例（A 有会话的 Mac、B 代替手机）、假扩展、打点的收集、负载与开销的记账。
打点是实例标准输出里的 `SYNCBENCH {json}` 行（DebugScene+SyncBench.swift），读线程按行收进 `Instance.events`，场景按事件等、不按时间猜。
"""
from collections import defaultdict
import hashlib, json, os, random, re, select, shutil, socket, subprocess, sys, threading, time

sys.dont_write_bytecode = True
from app_env import isolated_env  # noqa: E402

SESSIONS = int(os.environ.get("SYNC_BENCH_SESSIONS", 3))
FLIP = float(os.environ.get("SYNC_BENCH_FLIP", 8))
STATES = [{"kind": "thinking"}, {"kind": "tool", "tool": "bash", "tools": ["bash"], "detail": "pnpm test"},
          {"kind": "compacting"}, {"kind": "done", "aborted": False}, {"kind": "idle"}]


REAL_LIBS = "/tmp/cuepad-sync-bench/real-libraries"
PEER = "mac-bench-a"  # A 的主机标识（-CuePadHost bench-a）：B 对会话说话点名这台


def exe_of(checkout):
    return f"{checkout}/apple/.derived/Build/Products/Debug/CuePad.app/Contents/MacOS/CuePad"


class Aborted(Exception):
    """实例没了（真 iCloud 的运行到了时限被收掉，或崩了）：场景就此结束，已量到的照记。"""


class Instance:
    """一个隔离实例。role：a（host）或 b（remote）。库在 home/library；cloud 是连哪朵云的启动参数（`Run`）。"""

    def __init__(self, role, checkout, out, relay, home, cloud):
        self.role, self.checkout, self.out, self.relay, self.home, self.cloud = role, checkout, out, relay, home, cloud
        self.sockets = f"/tmp/cpsb-{role}-{os.getpid()}"  # 每次运行一份：别的运行留下的假扩展连不进来
        os.makedirs(self.sockets, mode=0o700, exist_ok=True); os.chmod(self.sockets, 0o700)
        self.events, self.cond, self.proc, self.started = [], threading.Condition(), None, None
        self.raw = open(f"{out}/{role}.log", "a", buffering=1)

    def start(self):
        env = dict(isolated_env(f"{self.home}/library", self.sockets), CUEPAD_SHOT_READY=f"{self.home}/ready")
        args = [exe_of(self.checkout), "-CuePadCloudKit", "YES", "-CuePadHost", f"bench-{self.role}",
                "-CuePadSyncBench", "host" if self.role == "a" else "remote", "-CuePadOffscreen", "YES", "-CuePadScene", "cue"]
        if self.role == "a": args += ["-CuePadCueBrain", f"{self.checkout}/apple/scripts/cue-brain-stub.py"]
        if not self.relay: args += ["-CuePadSyncBenchNoRelay", "YES"]
        args += self.cloud
        self.started = time.time()
        self.proc = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        threading.Thread(target=self._read, args=(self.proc,), daemon=True).start()
        self.raw.write(f"--- start {self.started:.3f} pid={self.proc.pid}\n")
        return self.started

    def _read(self, proc):
        for line in proc.stdout:
            self.raw.write(line)
            if not line.startswith("SYNCBENCH "): continue
            try: event = json.loads(line[10:])
            except ValueError: continue
            event["pid"] = proc.pid
            with self.cond:
                self.events.append(event); self.cond.notify_all()
        self.raw.flush()

    @property
    def pid(self): return self.proc.pid

    def alive(self): return self.proc is not None and self.proc.poll() is None

    def send(self, line):
        """给实例一条命令（`SyncBench.command`），返回发出时刻。"""
        sent = time.time()
        try:
            self.proc.stdin.write(line + "\n"); self.proc.stdin.flush()
        except (BrokenPipeError, ValueError):
            raise Aborted(f"{self.role} 已退出")
        return sent

    def wait(self, match, timeout, after=0.0):
        """等第一条 t ≥ after 且 match(event) 的打点；超时 None。"""
        end = time.time() + timeout
        with self.cond:
            while True:
                for event in self.events:
                    if event["t"] >= after and match(event): return event
                left = end - time.time()
                if left <= 0 or not self.alive(): return None
                self.cond.wait(left)

    def first(self, event_name, id):
        return next((e for e in self.events if e["e"] == event_name and e.get("id") == id), None)

    def stop(self):
        if not self.alive(): return
        self.proc.stdin.close()
        self.proc.terminate()
        try: self.proc.wait(15)
        except subprocess.TimeoutExpired: self.proc.kill(); self.proc.wait()


class Metrics(defaultdict):
    def __init__(self): super().__init__(list)

    def span(self, name, start, end):
        if start and end: self[name].append(round(end["t"] - start["t"], 3))
        elif start: self[name + "（超时）"].append(1)


def kind(name, author=None):
    return lambda e: e["e"] == name and (author is None or e.get("author") == author)


class Load:
    """这次运行期间机器的 1 分钟负载，每 5 秒一次。"""

    def __init__(self):
        self.samples, self.stopped = [], threading.Event()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        while not self.stopped.wait(5): self.samples.append(os.getloadavg()[0])

    def summary(self):
        self.stopped.set()
        s = self.samples or [os.getloadavg()[0]]
        return {"mean": round(sum(s) / len(s), 1), "max": round(max(s), 1), "cpus": os.cpu_count()}


def extension_version(checkout):
    source = open(f"{checkout}/apple/CuePadKit/Sources/CuePi/Extension/cuepad-bridge/index.ts").read()
    return int(re.search(r"const EXTENSION_VERSION = (\d+);", source).group(1)), int(re.search(r"const PROTOCOL_VERSION = (\d+);", source).group(1))


def fake_extension(directory, checkout):
    """假扩展（子进程里跑）：SESSIONS 个会话，各自按指数分布的间隔切状态；任何带 id 的命令都回 ack ok。"""
    version, protocol = extension_version(checkout)
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
    running, parent = True, os.getppid()
    def stop(*_):
        nonlocal running; running = False
    import signal; signal.signal(signal.SIGTERM, stop)
    while running and os.getppid() == parent:  # 起它的脚本没了（被杀、崩了）就跟着收尾
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
                    if "id" in msg: send(c, {"t": "ack", "id": msg["id"], "ok": True})
            if time.time() >= s["next"]:
                state = dict(random.choice(STATES)); state["since"] = now()
                busy = state["kind"] not in ("idle", "done")
                state["busySince"] = s["state"].get("busySince") or now() if busy else None
                s["state"] = state; s["next"] = time.time() + random.expovariate(1 / FLIP)
                for c in s["clients"]: send(c, {"t": "state", "state": state})
    for s in sessions:  # 正常收尾：会话以"结束"同步出去，下次跑不会被当成在线的会话
        for c in s["clients"]: send(c, {"t": "bye", "reason": "quit"}); c.close()
        s["server"].close(); os.remove(s["path"])


class Run:
    """一次运行：起 A、假扩展、B，等两边连通（`warm`），场景跑完收尾。场景把样本记进 `metrics`（中途收掉也留着）。
    cloud：`sim` 是这次运行自己的模拟云（out/cloud，`SharedCloud`，延迟模型 latency）；`real` 连 iCloud 开发环境：
    库留在 REAL_LIBS 里接着用（不每次从头拉开发区的历史），每个实例至多 budget 个请求，整次运行到 limit 秒就收掉。"""

    def __init__(self, checkout, out, relay, cloud, latency=None, budget=None, limit=None):
        self.checkout, self.out, self.relay, self.limit, self.cloud = checkout, out, relay, limit, cloud
        os.makedirs(out, exist_ok=True)
        if cloud == "sim":
            os.makedirs(f"{out}/cloud")
            json.dump(latency, open(f"{out}/cloud/latency.json", "w"))
            args, home = ["-CuePadSyncBenchCloud", f"{out}/cloud"], out
        else:
            args, home = ["-CuePadSyncBenchBudget", str(budget)], f"{REAL_LIBS}/{hashlib.sha1(checkout.encode()).hexdigest()[:8]}"
        self.a, self.b = (Instance(r, checkout, out, relay, f"{home}/{r}", args) for r in ("a", "b"))
        self.extension, self.metrics, self.timer = None, Metrics(), None

    def __enter__(self):
        try:
            return self._start()
        except BaseException:
            self.__exit__()
            raise

    def _start(self):
        if self.limit:
            self.timer = threading.Timer(self.limit, self._expire); self.timer.daemon = True; self.timer.start()
        self.extension = subprocess.Popen([sys.executable, os.path.abspath(sys.argv[0]), "--fake-extension", self.a.sockets, self.checkout])
        self.a.start()
        if not self.a.wait(kind("ready"), 60):
            raise SystemExit(f"A 60 秒没有测量打点（{self.out}/a.log）：构建要含 DebugScene+SyncBench.swift 的打点（变基到含 climb/metrics 的 main）")
        self.b.start()
        if not self.b.wait(kind("ready"), 60): raise SystemExit(f"B 没就绪（{self.out}/b.log）")
        self.warm()
        return self

    def warm(self, limit=float(os.environ.get("SYNC_BENCH_WARM", 300))):
        """预热到整条路通：B 对 Cue 说的一句有了回执，对 A 的会话说的一句有了结果（B 第一次拉完开发区的历史、看到 A 的会话、Cue 值上班）。"""
        end, began = time.time() + limit, time.time()
        while time.time() < end:
            t = self.b.send("say warm")
            said = self.b.wait(kind("msg-write", "you"), 10, after=t - 1)
            if said and self.b.wait(lambda e: e["e"] == "msg-delivered" and e["id"] == said["id"], 40):
                t = self.b.send(f"send warm {PEER}")
                req = self.b.wait(kind("req-write"), 10, after=t - 1)
                if req and self.b.wait(lambda e: e["e"] == "req-done" and e["id"] == req["id"], 40):
                    print(f"  预热 {time.time() - began:.0f} 秒", flush=True)
                    return
            time.sleep(5)
        raise SystemExit(f"{limit:.0f} 秒没连通（{self.out}）")

    def _expire(self):
        print(f"  到了 {self.limit:.0f} 秒的时限，收掉实例", flush=True)
        self.metrics["到时限中止（次）"].append(1)
        self.b.stop(); self.a.stop()

    def __exit__(self, *_):
        if self.timer: self.timer.cancel()
        if self.extension: self.extension.terminate(); self.extension.wait()
        time.sleep(3)  # A 把会话结束同步出去
        self.b.stop(); self.a.stop()
        for directory in (self.a.sockets, self.b.sockets): shutil.rmtree(directory, ignore_errors=True)

