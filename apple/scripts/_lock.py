"""xc.sh 的入口锁（规则与用法见 _lock.sh 头注释）：按模式拿检出、模拟器、闸门与机器几把 flock，登记持有者，
在锁里起命令并守着它的时限，结束时连同它起的全部进程（swift test 的测试宿主、xcodebuild 的编译器各自另起进程组，按组结束会漏下它们）。
用法：_lock.py <时限秒> <等待上限秒> <报告间隔秒> <模拟器台数> <plain|sim|exclusive> <命令…>；锁与登记在 app_env.RUNTIME，本检出的锁在 apple/.derived/xc.lock
"""
import fcntl, json, os, shlex, signal, subprocess, sys, threading, time

sys.dont_write_bytecode = True
from app_env import APPLE, CHECKOUT, RUNTIME  # noqa: E402
from app_proc import descendants, silence, wait_exit  # noqa: E402

hold, wait_limit, report, pool, mode, *cmd = sys.argv[1:]
hold, wait_limit, report, pool = int(hold), int(wait_limit), int(report), int(pool)
holders, own = f"{RUNTIME}/holders", f"{APPLE}/.derived/xc.lock"
os.makedirs(holders, exist_ok=True)
os.makedirs(os.path.dirname(own), exist_ok=True)
begun = time.time()


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
    seconds = int(seconds)
    return f"{seconds // 60} 分 {seconds % 60:02d} 秒"


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
        me["waiting"] = None
    me["held"].append([options[free][1], time.time()])
    publish()
    return free


try:
    checkout = open(own, "a+")
    acquire([(checkout, f"检出 {me['checkout']}")], fcntl.LOCK_EX, "这个检出的上一个任务还在跑")
    sim = ""
    if mode == "sim":
        sims = [open(f"{RUNTIME}/sim{n}", "a+") for n in range(pool)]
        sim = str(acquire([(f, f"模拟器 {n}") for n, f in enumerate(sims)], fcntl.LOCK_EX, f"{pool} 台模拟器都在用"))
    gate, machine = open(f"{RUNTIME}/gate", "a+"), open(f"{RUNTIME}/machine", "a+")
    if mode == "exclusive":
        acquire([(gate, "闸门（独占）")], fcntl.LOCK_EX, "另一个性能测量在跑")
        acquire([(machine, "机器（独占）")], fcntl.LOCK_EX, "等在跑的编译、测试做完（性能测量独占机器）")
    else:
        acquire([(gate, "闸门")], fcntl.LOCK_SH, "性能测量在跑，它独占机器")
        fcntl.flock(machine, fcntl.LOCK_SH)  # 测量拿到 machine 前先占着 gate，过了 gate 这里就不会等
        fcntl.flock(gate, fcntl.LOCK_UN)
        me["held"] = [h for h in me["held"] if h[0] != "闸门"] + [["机器（共享）", time.time()]]
        publish()

    lease = f"{RUNTIME}/lease-{me['pid']}"  # run ios 留下实例时，看守把自己的 PID 写在这里（app_sim.keep）
    child = subprocess.Popen(cmd, env=dict(os.environ, CUEPAD_SIM=sim, CUEPAD_LEASE=lease))

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
        say(f"任务跑了 {hold // 60} 分钟还没完，连同它起的进程一起结束")
        signal_tree(signal.SIGTERM)
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            signal_tree(signal.SIGKILL)
        code = 124
    if code == 0 and os.path.exists(lease) and os.fork() == 0:
        # 租约：分身只带着这台模拟器的槽位锁（flock 跟着打开的文件描述符走，原进程退出不放），别的锁随分身关掉的描述符放掉，
        # 守到看守退出；登记换成分身的，排队的人看得到谁租着
        with open(lease) as f:
            watcher = int(f.read())
        os.remove(lease)
        os.setsid()
        silence()
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal.SIG_DFL)
        keep = sims[int(sim)].fileno()
        os.closerange(3, keep)
        os.closerange(keep + 1, 4096)
        me.update(pid=os.getpid(), start=processes([os.getpid()])[os.getpid()][1], cmd=me["cmd"] + "（租着这台模拟器）", held=[h for h in me["held"] if h[0].startswith("模拟器")])
        record = f"{holders}/{me['pid']}.json"
        publish()
        wait_exit(watcher)
        os.remove(record)
        os._exit(0)
finally:
    if os.path.exists(record):
        os.remove(record)
sys.exit(128 - code if code < 0 else code)
