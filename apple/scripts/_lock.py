"""xc.sh 的入口锁（规则与用法见 _lock.sh 头注释）：拿检出锁与（要模拟器的）一个模拟器槽位，登记持有者，
在锁里起命令并守着它的时限，结束时连同它起的全部进程（swift test 的测试宿主、xcodebuild 的编译器各自另起进程组，按组结束会漏下它们），再打一行用时。
用法：_lock.py <时限秒> <等待上限秒> <报告间隔秒> <模拟器槽位数> <机型，不要模拟器给空串> <命令…>；锁与登记在 app_env.RUNTIME，本检出的锁在 apple/.derived/xc.lock
"""
import fcntl, json, os, re, shlex, signal, subprocess, sys, threading, time

sys.dont_write_bytecode = True
from app_env import APPLE, CHECKOUT, RUNTIME  # noqa: E402
from app_proc import descendants  # noqa: E402

hold, wait_limit, report, slots, model, *cmd = sys.argv[1:]
hold, wait_limit, report, slots = int(hold), int(wait_limit), int(report), int(slots)
holders, own = f"{RUNTIME}/holders", f"{APPLE}/.derived/xc.lock"
os.makedirs(holders, exist_ok=True)
os.makedirs(os.path.dirname(own), exist_ok=True)
begun = time.time()
phases = {"排队": 0}  # 名字 → 秒，打在结束时的用时行里；命令自己量的段（xc.sh 的 phase）写在 phase_file，结束时并进来
phase_file = f"{RUNTIME}/phases-{os.getpid()}"


def processes(pids):
    """pid → (状态, 起始时刻)；不在的不在其中。起始时刻认 PID 有没有被别的进程复用。"""
    if not pids:
        return {}
    out = subprocess.run(["ps", "-o", "pid=,stat=,lstart=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    return {int(line.split(None, 2)[0]): tuple(part.strip() for part in line.split(None, 2)[1:]) for line in out.splitlines()}


me = {"pid": os.getpid(), "start": processes([os.getpid()])[os.getpid()][1], "checkout": CHECKOUT,
      "cmd": shlex.join(cmd), "held": [], "waiting": None}
record = f"{holders}/{me['pid']}.json"


def publish():
    with open(record + ".tmp", "w") as f:
        json.dump(me, f, ensure_ascii=False)
    os.replace(record + ".tmp", record)


def others():
    """此刻还活着的别的持有者（持有或在等）；进程没了或 PID 已是别的进程的条目当场删掉。"""
    found = []
    for name in os.listdir(holders):
        try:
            with open(f"{holders}/{name}") as f:
                found.append(json.load(f))
        except (OSError, ValueError):
            pass
    alive = processes([h["pid"] for h in found])
    live = []
    for h in found:
        if h["pid"] == me["pid"]:
            continue
        if alive.get(h["pid"], (None, None))[1] != h["start"]:
            try:
                os.remove(f"{holders}/{h['pid']}.json")
            except FileNotFoundError:
                pass
            continue
        live.append((h, alive[h["pid"]][0]))
    return sorted(live, key=lambda item: min((t for _, t in item[0]["held"]), default=time.time()))


def clock(seconds):
    minutes, seconds = divmod(round(seconds), 60)
    return f"{minutes} 分 {seconds:02d} 秒" if minutes else f"{seconds} 秒"


def line(text):
    """显示时截成一行：命令行可以很长（测量的启动参数），排队的报告每个持有者一行命令。"""
    return text if len(text) <= COMMAND_WIDTH else text[:COMMAND_WIDTH - 1] + "…"


COMMAND_WIDTH = 150


def listing():
    """登记的持有者：每把锁拿到多久、在等什么、命令。"""
    now, lines = time.time(), []
    for h, stat in others():
        if not h["held"]:
            continue
        # 各把锁从真正拿到的那一刻算，不含排队等它的时间
        held = "、".join(f"{name}（{time.strftime('%H:%M:%S', time.localtime(since))} 拿到，已持有 {clock(now - since)}）" for name, since in h["held"])
        entry = f"  pid {h['pid']}  {h['checkout']}  持有 {held}"
        if h["waiting"]:
            entry += f"，在等 {h['waiting']}"
        if stat.startswith("T"):
            entry += "  （进程停住了：不受时限管，要有人 kill -CONT 或结束它）"
        lines.append(f"{entry}\n    命令：{line(h['cmd'])}")
    return "\n".join(lines) or "  （此刻没有持有者：锁马上就会空出）"


def say(text):
    print(text, file=sys.stderr, flush=True)


def take(f, kind):
    try:
        fcntl.flock(f, kind | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def acquire(options, kind, why):
    """拿到 options（(文件, 名字)）里任一把，记进持有；都占着就排队，每 report 秒列一次持有者，过了等待上限报错退出。"""
    free = next((n for n, (f, _) in enumerate(options) if take(f, kind)), None)
    if free is None:
        me["waiting"] = why
        publish()
        blocked = time.time()
        say(f"排队：{why}\n{listing()}")
        # 每把一个线程阻塞在 flock 上，先拿到的算数，其余拿到后马上放掉
        won, pick, result = threading.Event(), threading.Lock(), []

        def claim(n):
            fcntl.flock(options[n][0], kind)
            with pick:
                if result:
                    fcntl.flock(options[n][0], fcntl.LOCK_UN)
                    return
                result.append(n)
            won.set()

        for n in range(len(options)):
            threading.Thread(target=claim, args=(n,), daemon=True).start()
        deadline = begun + wait_limit
        while not won.wait(max(0, min(report, deadline - time.time()))):
            waited = int(time.time() - begun)
            if time.time() >= deadline:
                say(f"等了 {clock(waited)}还没轮到（上限 LOCK_WAIT）：{why}\n{listing()}")
                os.remove(record)
                os._exit(75)
            say(f"还在等（{clock(waited)}）：{why}\n{listing()}")
        free = result[0]
        phases["排队"] += time.time() - blocked
        me["waiting"] = None
    me["held"].append([options[free][1], time.time()])
    publish()
    return free


POOL_NAME = re.compile(r"CuePad (.+) #(\d+)")


def booted_pool():
    """开着的本项目模拟器（名为"CuePad <机型> #<号>"）：[(UDID, 机型, 号)]。别的模拟器不碰。"""
    out = subprocess.run(["xcrun", "simctl", "list", "devices", "booted", "-j"], capture_output=True, text=True, check=True, timeout=60).stdout
    return [(d["udid"], m[1], int(m[2])) for devices in json.loads(out)["devices"].values() for d in devices if (m := POOL_NAME.fullmatch(d["name"]))]


def free_slot_order():
    """槽位的领取顺序：已开着这一机型的在前（不用重开机），空槽居中，开着别的机型的最后（要先关它）。"""
    have = {n: {m for _, m, k in booted_pool() if k == n} for n in range(slots)}
    return sorted(range(slots), key=lambda n: 0 if model in have[n] else 2 if have[n] else 1)


def clear_slots(files, slot):
    """持着槽位 slot 时收拾模拟器：每个槽位同一时刻最多开着一台，全机开机数封在槽位数以内。
    关掉自己槽位上别的机型的；别的槽位（编号超出槽位数的是旧版每机型一池留下的）只动拿得到锁的空闲槽位：超出的全关，槽位内多开的留一台（优先自己的机型）。
    持着它的锁关完才放；关不掉就报错退出，不带着多开的模拟器往下跑。"""
    by_slot = {}
    for udid, m, n in booted_pool():
        by_slot.setdefault(n, []).append((udid, m))
    stale, locked = [], []
    for n, devices in by_slot.items():
        if n == slot:
            stale += [u for u, m in devices if m != model]
        elif n >= slots or len(devices) > 1:
            f = files[n] if n < slots else open(f"{RUNTIME}/sim{n}", "a+")
            if not take(f, fcntl.LOCK_EX):
                continue
            locked.append(f)
            keep = None if n >= slots else next((u for u, m in devices if m == model), devices[0][0])
            stale += [u for u, _ in devices if u != keep]
    for p in [subprocess.Popen(["xcrun", "simctl", "shutdown", udid]) for udid in stale]:
        p.wait()
    # 退出码不可信：另一个任务刚把它关了也会报错。以还开着为准
    left = [name for udid, m, n in booted_pool() if udid in stale for name in [f"CuePad {m} #{n}"]]
    if left:
        raise SystemExit(f"关不掉模拟器：{'、'.join(left)}")
    for f in locked:
        fcntl.flock(f, fcntl.LOCK_UN)


def summary(total):
    """结束时的用时行：排队、命令自己量的段（编译等）、其余，与此刻 1 分钟负载（负载高于核数时，帧与时长不可比，只比指令数）。"""
    try:
        for entry in open(phase_file):
            name, seconds = entry.split()
            phases[name] = phases.get(name, 0) + int(seconds)
    except FileNotFoundError:
        pass
    shown = [f"{name} {clock(seconds)}" for name, seconds in phases.items() if seconds >= 1 or name == "排队"]
    rest = max(0, total - sum(phases.values()))
    say(f"用时 {clock(total)}：{'、'.join(shown)}、其余 {clock(rest)} · 1 分钟负载 {os.getloadavg()[0]:.0f}")


try:
    checkout = open(own, "a+")
    acquire([(checkout, f"检出 {me['checkout']}")], fcntl.LOCK_EX, "这个检出的上一个任务还在跑")
    sim = ""
    if model:
        files = {n: open(f"{RUNTIME}/sim{n}", "a+") for n in range(slots)}
        order = free_slot_order()
        sim = str(order[acquire([(files[n], f"模拟器槽位 {n}") for n in order], fcntl.LOCK_EX, f"{slots} 个模拟器槽位都在用")])
        cleared = time.time()
        clear_slots(files, int(sim))
        phases["关旧模拟器"] = time.time() - cleared

    child = subprocess.Popen(cmd, env=dict(os.environ, CUEPAD_SIM=sim, CUEPAD_PHASES=phase_file))

    def signal_tree(sig, _=None):
        for pid in reversed([child.pid, *descendants(child.pid)]):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, signal_tree)
    try:
        code = child.wait(timeout=hold)
    except subprocess.TimeoutExpired:
        say(f"任务跑了 {clock(hold)}还没完，连同它起的进程一起结束")
        signal_tree(signal.SIGTERM)
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            signal_tree(signal.SIGKILL)
        code = 124
    summary(time.time() - begun)
finally:
    for path in (record, phase_file):
        if os.path.exists(path):
            os.remove(path)
sys.exit(128 - code if code < 0 else code)
