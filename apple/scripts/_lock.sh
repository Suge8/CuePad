# shellcheck shell=bash
# xc.sh 的入口锁，三条规则：
# 1. 同一检出一次一个任务（<检出>/apple/.derived/xc.lock）：同一产物目录上的两个 xcodebuild 会抢构建数据库、互相覆盖产物。
#    不同检出之间不设上限：实测同时 9 个增量编译测试，不排队比限 3 个快（链接、签名、起测试宿主时 CPU 空着，并发正好填上）。
# 2. 只有前台、和交互预算比的 Mac 测量（xc.sh perf mac … -CuePadForeground YES）独占机器：普通任务持 /tmp/cuepad-xc-<uid>/machine 的共享锁，
#    它要独占锁，并先占闸门（gate）让后来的普通任务停在门外，不被源源不断的新任务饿死。别的测量只比指令数，不独占。
# 3. iOS 的测试、截图、录屏从固定的 SIM_POOL 台模拟器里领一台（每台一把锁，见 _sim.sh），全占着就等空出一台。
#    先领模拟器再进 machine：排队等模拟器的任务不占着机器（曾经占着，测量就跟着整条模拟器队列一起等）。
# 锁都是 flock，只由这里的入口进程持有（Python 打开的文件不传给子进程），它退出时内核释放，崩了也不留死锁。持有者把 CUEPAD_SIM=<模拟器号，没领为空> 传给子进程，
# 脚本再调脚本不重复进锁。任务最多跑 HOLD_LIMIT 秒，超了连同它起的全部进程结束，防止卡死的任务一直占着。
# 谁拿着锁记在 /tmp/cuepad-xc-<uid>/holders/<PID>.json（PID、检出、完整命令行、持有的每把锁与真正拿到它的时刻、在等的锁），入口退出时删掉；
# 被 KILL 留下的、PID 已不是那个进程的，读的人当场清掉。排队时开头与每 LOCK_REPORT 秒列一次持有者：每把锁持有了多久（不含排队），命令截成一行，
# 停住的进程标出来（它不受时限管）；
# 等满 LOCK_WAIT 秒还没轮到就列出持有者、以 75 退出，不静默挂着。
# 用法：xc_enter <plain|sim|exclusive> <命令…>，在锁里 exec 这条命令（通常是 "$0" "$@"）；exclusive 只给前台的 Mac 交互测量。

SIM_POOL=3
HOLD_LIMIT=1800
LOCK_REPORT=30
# 前面的任务都受 HOLD_LIMIT 管，正常排队等不过一个任务的时限（另留收尾的余量）；超过它，是前面有停住的进程、
# 或排着不止一件长任务，报出来让人处理。等得起更久的给 CUEPAD_LOCK_WAIT=<秒>
LOCK_WAIT=${CUEPAD_LOCK_WAIT:-$((HOLD_LIMIT + 300))}

xc_enter() {
  [ -z "${CUEPAD_SIM+set}" ] || return 0
  # 独占期间所有检出的新任务都停在闸门外：别的脚本借它（实测有借来录一批屏的）就挡住所有人
  if [ "$1" = exclusive ] && [ "${2##*/}" != perf-mac.sh ]; then
    echo "独占机器只给前台和预算比的交互测量（xc.sh perf mac … -CuePadForeground YES）；录屏、截图与别的测量照普通任务跑，前后对比看指令数" >&2
    exit 2
  fi
  mkdir -p "$APPLE_DIR/.derived"
  # 不用 "$(cat <<'PY' …)"：macOS 自带的 bash 3.2 解析命令替换里的这段时会把它重复成两个参数
  local script
  IFS= read -r -d '' script <<'PY' || true
import fcntl, json, os, re, shlex, signal, subprocess, sys, threading, time

hold, wait_limit, report, pool, root, own, mode, *cmd = sys.argv[1:]
hold, wait_limit, report, pool = int(hold), int(wait_limit), int(report), int(pool)
holders = f"{root}/holders"
os.makedirs(holders, exist_ok=True)
begun = time.time()


def processes(pids):
    """pid → (状态, 起始时刻)；不在的不在其中。起始时刻认 PID 有没有被别的进程复用。"""
    if not pids:
        return {}
    out = subprocess.run(["ps", "-o", "pid=,stat=,lstart=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    return {int(line.split(None, 2)[0]): tuple(part.strip() for part in line.split(None, 2)[1:]) for line in out.splitlines()}


me = {"pid": os.getpid(), "start": processes([os.getpid()])[os.getpid()][1], "checkout": os.path.dirname(os.path.dirname(os.path.dirname(own))),
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


def listing(files):
    """登记的持有者，加上开着 files（在等的锁文件）却没登记的进程（还没换上这版入口的检出）。"""
    now, lines, live = time.time(), [], others()
    known = {h["pid"] for h, _ in live} | {me["pid"]}
    opened = subprocess.run(["lsof", "-t", *[f.name for f in files]], capture_output=True, text=True).stdout.split()
    for pid in sorted({int(p) for p in opened} - known):
        command = subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        # 旧版入口的命令行末尾是"…<检出>/apple/.derived/xc.lock <模式> <命令…>"
        task = re.search(r"(\S+)/apple/\.derived/xc\.lock (\S+) (.*)$", command)
        what = f"{task[1]}  {task[2]}\n    命令：{line(task[3])}" if task else line(command)
        lines.append(f"  pid {pid}  （没登记：旧版入口，持有或在等）  {what}")
    for h, stat in live:
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
        files = [f for f, _ in options]
        say(f"排队：{why}\n{listing(files)}")
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
                say(f"等了 {clock(waited)}还没轮到（上限 LOCK_WAIT）：{why}\n{listing(files)}")
                os.remove(record)
                os._exit(75)
            say(f"还在等（{clock(waited)}）：{why}\n{listing(files)}")
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
        sims = [open(f"{root}/sim{n}", "a+") for n in range(pool)]
        sim = str(acquire([(f, f"模拟器 {n}") for n, f in enumerate(sims)], fcntl.LOCK_EX, f"{pool} 台模拟器都在用"))
    gate, machine = open(f"{root}/gate", "a+"), open(f"{root}/machine", "a+")
    if mode == "exclusive":
        acquire([(gate, "闸门（独占）")], fcntl.LOCK_EX, "另一个性能测量在跑")
        acquire([(machine, "机器（独占）")], fcntl.LOCK_EX, "等在跑的编译、测试做完（性能测量独占机器）")
    else:
        acquire([(gate, "闸门")], fcntl.LOCK_SH, "性能测量在跑，它独占机器")
        fcntl.flock(machine, fcntl.LOCK_SH)  # 测量拿到 machine 前先占着 gate，过了 gate 这里就不会等
        fcntl.flock(gate, fcntl.LOCK_UN)
        me["held"] = [h for h in me["held"] if h[0] != "闸门"] + [["机器（共享）", time.time()]]
        publish()

    child = subprocess.Popen(cmd, env=dict(os.environ, CUEPAD_SIM=sim))

    def tree(top):
        """top 与它的全部后代：swift test 的测试宿主、xcodebuild 的编译器各自另起进程组，按组结束会漏下它们。"""
        children = {}
        for line in subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.splitlines():
            pid, ppid = map(int, line.split())
            children.setdefault(ppid, []).append(pid)
        found, todo = [], [top]
        while todo:
            pid = todo.pop()
            found.append(pid)
            todo += children.get(pid, [])
        return found

    def signal_tree(sig, _=None):
        for pid in reversed(tree(child.pid)):
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
finally:
    if os.path.exists(record):
        os.remove(record)
sys.exit(128 - code if code < 0 else code)
PY
  exec python3 -c "$script" "$HOLD_LIMIT" "$LOCK_WAIT" "$LOCK_REPORT" "$SIM_POOL" "/tmp/cuepad-xc-$UID" "$APPLE_DIR/.derived/xc.lock" "$@"
}
