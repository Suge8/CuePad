"""全机的锁与持有者登记：谁拿着哪把锁、在等哪把，只记在这一处（运行目录 app_env.RUNTIME 的 holders/<PID>.json）。
锁都是 flock，进程退出（连同继承了描述符的子进程都关掉）时内核释放，崩了也不留死锁；登记在持有者正常退出时删，
被 KILL 留下的、PID 已不是那个进程的（按 ps 的启动时刻认），读的人当场清掉。
用它的：xc.sh 的入口锁（task、signing 两种用法，规则见 _lock.sh 头注释）、Mac 实例位（app_mac.py）、同步测量（sync-bench.py）、发布（release-context.py）。
锁名全机唯一（按检出分的带上检出路径），读登记的人按锁名找持有者（holding）。
_lock.py task <时限秒> <等待上限秒> <报告间隔秒> <模拟器准备期限秒> <模拟器槽位数> <机型，不要模拟器给空串> <命令…>
  拿检出锁（apple/.derived/xc.lock）与（要模拟器的）一个模拟器槽位，准备模拟器（列出、关旧的；每步受准备期限管，超了结束自己起的 simctl、报错退出并放锁），
  在锁里起命令并守着它的时限，结束时连同它起的全部进程（swift test 的测试宿主、xcodebuild 的编译器各自另起进程组，按组结束会漏下它们），再打一行用时。
_lock.py signing <等待上限秒> <报告间隔秒> <脚本 PID> <描述符>
  在脚本打开的描述符上拿全机的签名锁（规则 3），登记后返回，标准输出是登记文件；锁在脚本与它起的进程都关掉描述符时放掉。
"""
import atexit, fcntl, json, os, re, shlex, signal, subprocess, sys, threading, time

sys.dont_write_bytecode = True
from app_env import APPLE, CHECKOUT, RUNTIME  # noqa: E402
from app_proc import descendants, silence, wait_exit  # noqa: E402

HOLDERS = f"{RUNTIME}/holders"
COMMAND_WIDTH = 150


def processes(pids):
    """pid → (状态, 起始时刻)；不在的不在其中。起始时刻认 PID 有没有被别的进程复用。"""
    if not pids:
        return {}
    out = subprocess.run(["ps", "-o", "pid=,stat=,lstart=", "-p", ",".join(map(str, pids))], capture_output=True, text=True).stdout
    return {int(line.split(None, 2)[0]): tuple(part.strip() for part in line.split(None, 2)[1:]) for line in out.splitlines()}


def clock(seconds):
    minutes, seconds = divmod(round(seconds), 60)
    return f"{minutes} 分 {seconds:02d} 秒" if minutes else f"{seconds} 秒"


def say(text):
    print(text, file=sys.stderr, flush=True)


def take(f, kind=fcntl.LOCK_EX):
    try:
        fcntl.flock(f, kind | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def lock_path(f):
    """打开着的锁文件（或描述符）在磁盘上的路径。"""
    return os.fsdecode(fcntl.fcntl(f, fcntl.F_GETPATH, bytes(1024)).rstrip(b"\0"))


def live():
    """此刻还活着的持有者登记 [(登记, ps 状态)]，按最早拿到锁的先后；进程没了或 PID 已是别的进程的条目当场删掉。"""
    found = []
    os.makedirs(HOLDERS, exist_ok=True)
    for name in os.listdir(HOLDERS):
        try:
            with open(f"{HOLDERS}/{name}") as f:
                found.append(json.load(f))
        except (OSError, ValueError):
            pass
    alive = processes([h["pid"] for h in found])
    result = []
    for h in found:
        if alive.get(h["pid"], (None, None))[1] != h["start"]:
            try:
                os.remove(f"{HOLDERS}/{h['pid']}.json")
            except FileNotFoundError:
                pass
            continue
        result.append((h, alive[h["pid"]][0]))
    return sorted(result, key=lambda item: min((t for _, t in item[0]["held"]), default=time.time()))


def holding(name):
    """此刻登记着持有 name 这把锁的那一条；没有为 None（没有登记不等于锁空着，见 Holder.listing）。"""
    return next((h for h, _ in live() if any(n == name for n, _ in h["held"])), None)


class Holder:
    """一个进程在登记里的那一条。extra 是给读登记的人的字段（Mac 实例位记 what、app；模拟器 run 的看守记 role、app、device）。"""

    def __init__(self, cmd, pid=None, **extra):
        pid = pid or os.getpid()
        self.entry = {"pid": pid, "start": processes([pid])[pid][1], "checkout": CHECKOUT, "cmd": cmd, "held": [], "waiting": None, **extra}
        self.files = []  # 拿到的锁文件留在这里：文件对象被回收就关掉描述符、放掉锁

    @property
    def record(self):
        return f"{HOLDERS}/{self.entry['pid']}.json"

    def publish(self, **extra):
        self.entry.update(extra)
        os.makedirs(HOLDERS, exist_ok=True)
        with open(self.record + ".tmp", "w") as f:
            json.dump(self.entry, f, ensure_ascii=False)
        os.replace(self.record + ".tmp", self.record)

    def remove(self):
        if os.path.exists(self.record):
            os.remove(self.record)

    def add(self, name):
        self.entry["held"].append([name, time.time()])
        self.publish()

    def drop(self, name):
        self.entry["held"] = [h for h in self.entry["held"] if h[0] != name]
        self.publish() if self.entry["held"] else self.remove()

    def acquire(self, options, why, wait_limit, report, since=None):
        """拿到 options（(打开的锁文件, 名字)）里任一把，记进持有；都占着就排队，开头与每 report 秒列一次持有者，
        从 since（单调钟，缺省现在）起过了 wait_limit 秒还没轮到就列出持有者、删掉自己的登记、以 75 退出（wait_limit 为 0 不排队，当场这样退出）。返回拿到第几把与排了几秒。"""
        since = time.monotonic() if since is None else since
        free = next((n for n, (f, _) in enumerate(options) if take(f)), None)
        queued = 0.0
        if free is None:
            paths = [lock_path(f) for f, _ in options]
            if wait_limit == 0:
                say(f"{why}\n{self.listing(paths)}")
                self.remove()
                os._exit(75)
            self.publish(waiting=why)
            blocked = time.monotonic()
            say(f"排队：{why}\n{self.listing(paths)}")
            # 每把一个线程阻塞在 flock 上，先拿到的算数，其余拿到后马上放掉
            won, pick, result = threading.Event(), threading.Lock(), []

            def claim(n):
                fcntl.flock(options[n][0], fcntl.LOCK_EX)
                with pick:
                    if result:
                        fcntl.flock(options[n][0], fcntl.LOCK_UN)
                        return
                    result.append(n)
                won.set()

            for n in range(len(options)):
                threading.Thread(target=claim, args=(n,), daemon=True).start()
            deadline = since + wait_limit
            while not won.wait(max(0, min(report, deadline - time.monotonic()))):
                waited = int(time.monotonic() - since)
                if time.monotonic() >= deadline:
                    say(f"等了 {clock(waited)}还没轮到（上限 {clock(wait_limit)}）：{why}\n{self.listing(paths)}")
                    self.remove()
                    os._exit(75)
                say(f"还在等（{clock(waited)}）：{why}\n{self.listing(paths)}")
            free = result[0]
            queued = time.monotonic() - blocked
            self.entry["waiting"] = None
        self.files.append(options[free][0])
        self.add(options[free][1])
        return free, queued

    def listing(self, paths):
        """登记的持有者：每把锁拿到多久、在等什么、命令（一行；截断时指出登记文件，完整命令在那里）。没有登记不代表锁空着，见末尾的说明。"""
        now, lines = time.time(), []
        for h, stat in live():
            if h["pid"] == self.entry["pid"] or not h["held"]:
                continue
            # 各把锁从真正拿到的那一刻算，不含排队等它的时间
            held = "、".join(f"{name}（{time.strftime('%H:%M:%S', time.localtime(since))} 拿到，已持有 {clock(now - since)}）" for name, since in h["held"])
            entry = f"  pid {h['pid']}  {h['checkout']}  持有 {held}"
            if h["waiting"]:
                entry += f"，在等 {h['waiting']}"
            if stat.startswith("T"):
                entry += "  （进程停住了：不受时限管，要有人 kill -CONT 或结束它）"
            cmd = h["cmd"] if len(h["cmd"]) <= COMMAND_WIDTH else f"{h['cmd'][:COMMAND_WIDTH - 1]}…（完整命令：{HOLDERS}/{h['pid']}.json）"
            lines.append(f"{entry}\n    命令：{cmd}")
        return "\n".join(lines) or (
            "  （没有已登记的持有者：这不等于锁是空的。刚拿到锁还没登记、被结束的发版留下的仍开着锁文件的子进程，都不在登记里）\n"
            f"  锁文件：{'、'.join(paths)}\n"
            f"  只读排查：lsof {' '.join(shlex.quote(p) for p in paths)}（列出开着它的进程；开着不等于正持有，对照命令判断）。不要删锁文件：删后重建，新旧进程锁住的就是不同的文件，互斥失效。\n"
            "  下一步：等；等满上限会以 75 退出，那时重跑一次。确认某个进程是残留且没人在用，才对它的 PID 发 TERM；拿不准就请用户处理")


_me = None


def me(**extra):
    """本进程在登记里的那一条（一个进程一条，持有的锁都记在里面），进程正常退出时删。"""
    global _me
    if _me is None:
        _me = Holder(shlex.join(sys.argv))
        atexit.register(_me.remove)
    _me.entry.update(extra)
    return _me


def hold(path, name, why, wait_limit, report=60, **extra):
    """本进程拿一把锁并登记，持有到进程退出（描述符设成可继承：exec 后由新程序与它起的进程接着持有，登记照样有效，PID 不变）。
    占着就排队（见 Holder.acquire；wait_limit 为 0 即拿不到马上列出持有者、以 75 退出）。"""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    f = open(path, "a+")
    me(**extra).acquire([(f, name)], why, wait_limit, report)
    os.set_inheritable(f.fileno(), True)


# ---- xc.sh 的入口锁 ----

POOL_NAME = re.compile(r"CuePad (.+) #(\d+)")


def task(hold_limit, wait_limit, report, prep, slots, model, cmd):
    begun = time.monotonic()  # 等待与用时都按单调钟算：调系统时间不改变期限；持有时刻只用来显示，按墙钟
    phases = {"排队": 0}  # 名字 → 秒，打在结束时的用时行里；命令自己量的段（xc.sh 的 phase）写在 phase_file，结束时并进来
    phase_file = f"{RUNTIME}/phases-{os.getpid()}"
    me = Holder(shlex.join(cmd))

    def prep_failed(what):
        raise SystemExit(f"准备模拟器超过 {prep} 秒仍没完成（卡在：{what}）：simctl 没有响应。已结束本次自己起的 simctl，放掉锁；可能已关掉了一部分旧模拟器。\n"
                         "下一步：直接重跑一次；再超时就是这台 Mac 的 CoreSimulator 服务卡住，请用户处理（重启该服务或重启 Mac），不要自己结束别的进程；"
                         "机器很忙时用 CUEPAD_SIM_PREP_LIMIT=<秒> 放宽这个期限。")

    def booted_pool(until):
        """开着的本项目模拟器（名为"CuePad <机型> #<号>"）：[(UDID, 机型, 号)]。别的模拟器不碰。until：准备期限的截止时刻（单调钟）。"""
        try:
            out = subprocess.run(["xcrun", "simctl", "list", "devices", "booted", "-j"], capture_output=True, text=True, check=True,
                                 timeout=max(1, until - time.monotonic())).stdout
        except subprocess.TimeoutExpired:
            prep_failed("列出开着的模拟器")
        return [(d["udid"], m[1], int(m[2])) for devices in json.loads(out)["devices"].values() for d in devices if (m := POOL_NAME.fullmatch(d["name"]))]

    def free_slot_order():
        """槽位的领取顺序：已开着这一机型的在前（不用重开机），空槽居中，开着别的机型的最后（要先关它）。"""
        have = {n: {m for _, m, k in booted_pool(time.monotonic() + prep) if k == n} for n in range(slots)}
        return sorted(range(slots), key=lambda n: 0 if model in have[n] else 2 if have[n] else 1)

    def clear_slots(files, slot):
        """持着槽位 slot 时收拾模拟器：每个槽位同一时刻最多开着一台，全机开机数封在槽位数以内。
        关掉自己槽位上别的机型的；别的槽位只动拿得到锁的空闲槽位：多开的留一台（优先自己的机型）。
        持着它的锁关完才放；关不掉就报错退出，不带着多开的模拟器往下跑。整段受准备期限管。"""
        until = time.monotonic() + prep
        by_slot = {}
        for udid, m, n in booted_pool(until):
            by_slot.setdefault(n, []).append((udid, m))
        stale, locked = [], []
        for n, devices in by_slot.items():
            if n == slot:
                stale += [u for u, m in devices if m != model]
            elif n < slots and len(devices) > 1:
                if not take(files[n]):
                    continue
                locked.append(files[n])
                keep = next((u for u, m in devices if m == model), devices[0][0])
                stale += [u for u, _ in devices if u != keep]
        shutdowns = [subprocess.Popen(["xcrun", "simctl", "shutdown", udid]) for udid in stale]
        for p in shutdowns:
            try:
                p.wait(max(0, until - time.monotonic()))
            except subprocess.TimeoutExpired:
                for q in shutdowns:
                    q.kill()
                prep_failed("关旧模拟器")
        # 退出码不可信：另一个任务刚把它关了也会报错。以还开着为准
        left = [name for udid, m, n in booted_pool(until) if udid in stale for name in [f"CuePad {m} #{n}"]]
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
        own = f"{APPLE}/.derived/xc.lock"
        os.makedirs(os.path.dirname(own), exist_ok=True)
        phases["排队"] += me.acquire([(open(own, "a+"), f"检出 {CHECKOUT}")], "这个检出的上一个任务还在跑", wait_limit, report, begun)[1]
        sim = ""
        if model:
            files = {n: open(f"{RUNTIME}/sim{n}", "a+") for n in range(slots)}
            order = free_slot_order()
            index, queued = me.acquire([(files[n], f"模拟器槽位 {n}") for n in order], f"{slots} 个模拟器槽位都在用", wait_limit, report, begun)
            sim, phases["排队"] = str(order[index]), phases["排队"] + queued
            cleared = time.monotonic()
            clear_slots(files, int(sim))
            phases["关旧模拟器"] = time.monotonic() - cleared

        lease = f"{RUNTIME}/lease-{os.getpid()}"  # run ios 留下实例时，看守把自己的 PID 写在这里（app_sim.keep）
        child = subprocess.Popen(cmd, env=dict(os.environ, CUEPAD_SIM=sim, CUEPAD_PHASES=phase_file, CUEPAD_LEASE=lease))

        def signal_tree(sig, _=None):
            for pid in reversed([child.pid, *descendants(child.pid)]):
                try:
                    os.kill(pid, sig)
                except ProcessLookupError:
                    pass

        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, signal_tree)
        try:
            code = child.wait(timeout=hold_limit)
        except subprocess.TimeoutExpired:
            say(f"任务跑了 {clock(hold_limit)}还没完，连同它起的进程一起结束")
            signal_tree(signal.SIGTERM)
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                signal_tree(signal.SIGKILL)
            code = 124
        summary(time.monotonic() - begun)
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
            keep = files[int(sim)].fileno()
            os.closerange(3, keep)
            os.closerange(keep + 1, 4096)
            lessee = Holder(me.entry["cmd"] + "（租着这台模拟器）")
            lessee.entry["held"] = [h for h in me.entry["held"] if h[0].startswith("模拟器")]
            lessee.publish()
            wait_exit(watcher)
            lessee.remove()
            os._exit(0)
    finally:
        me.remove()
        if os.path.exists(phase_file):
            os.remove(phase_file)
    sys.exit(128 - code if code < 0 else code)


def signing(wait_limit, report, owner, fd):
    """规则 3：在脚本传下来的描述符（打开的描述文件目录）上排队拿锁。锁跟着这份打开的文件走：脚本和它起的进程（xcodebuild 等）
    都关掉它才放，脚本被 kill 而归档还在跑时照样持着。登记挂在脚本名下，打印登记文件给 signing_end 删；脚本没走到那一步就退出时，读的人当场清掉。"""
    cmd = subprocess.run(["ps", "-o", "command=", "-p", str(owner)], capture_output=True, text=True).stdout.strip()
    me = Holder(cmd, pid=owner)
    try:
        me.acquire([(fd, "签名（全机）")], "别的检出在生成描述文件或签名归档", wait_limit, report)
    except BaseException:
        me.remove()
        raise
    print(me.record, flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "signing":
        signing(*map(int, sys.argv[2:6]))
    else:
        hold_limit, wait_limit, report, prep, slots, model, *cmd = sys.argv[2:]
        task(int(hold_limit), int(wait_limit), int(report), int(prep), int(slots), model, cmd)
