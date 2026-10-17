# shellcheck shell=bash
# xc.sh 的入口锁，三条规则：
# 1. 同一检出一次一个任务（<检出>/apple/.derived/xc.lock）：同一产物目录上的两个 xcodebuild 会抢构建数据库、互相覆盖产物。
#    不同检出之间不设上限：实测同时 9 个增量编译测试，不排队比限 3 个快（链接、签名、起测试宿主时 CPU 空着，并发正好填上）。
# 2. 交互性能测量的那一段独占机器（xc.sh perf 先照普通任务构建，再进这把锁）：普通任务持 /tmp/cuepad-xc-<uid>/machine 的共享锁，测量要独占锁；测量先占闸门（gate），
#    后来的普通任务停在闸门外，测量不会被源源不断的新任务饿死。
# 3. iOS 的测试、截图、录屏从固定的 SIM_POOL 台模拟器里领一台（每台一把锁，见 _sim.sh），全占着就等空出一台。
# 锁都是 flock，持有进程退出时内核释放，崩了也不留死锁。持有者把 CUEPAD_SIM=<模拟器号，没领为空> 传给子进程，
# 脚本再调脚本不重复进锁。任务最多跑 HOLD_LIMIT 秒，超了连同它起的全部进程结束，防止卡死的任务一直占着。
# 用法：脚本开头 xc_enter <plain|sim|exclusive> "$0" "$@"；exclusive 是性能测量（用 0 号模拟器）。

SIM_POOL=3
HOLD_LIMIT=1800

xc_enter() {
  [ -z "${CUEPAD_SIM+set}" ] || return 0
  mkdir -p "$APPLE_DIR/.derived"
  exec python3 -c "$(cat <<'PY'
import fcntl, os, signal, subprocess, sys, threading, time

limit, pool, root, own, mode, *cmd = sys.argv[1:]
limit, pool = int(limit), int(pool)
os.makedirs(root, exist_ok=True)
me = f"pid {os.getpid()}  {os.getcwd()}  {os.path.basename(cmd[0])} {' '.join(cmd[1:3])}"


def take(f, kind=fcntl.LOCK_EX):
    try:
        fcntl.flock(f, kind | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False


def wait(f, kind, why):
    if not take(f, kind):
        print(f"排队：{why}", file=sys.stderr, flush=True)
        fcntl.flock(f, kind)


def note(f):
    f.seek(0)
    return f.read().strip() or "?"


def mark(f, text):
    f.truncate(0)
    f.write(text)
    f.flush()


checkout = open(own, "a+")
wait(checkout, fcntl.LOCK_EX, f"这个检出的上一个任务还在跑\n  {note(checkout)}")
held = [checkout]

gate, machine = open(f"{root}/gate", "a+"), open(f"{root}/machine", "a+")
if mode == "exclusive":
    wait(gate, fcntl.LOCK_EX, "另一个性能测量在跑")
    wait(machine, fcntl.LOCK_EX, "等在跑的编译、测试做完（性能测量独占机器）")
    sim = "0"
else:
    wait(gate, fcntl.LOCK_SH, "性能测量在跑，它独占机器")
    fcntl.flock(machine, fcntl.LOCK_SH)  # 测量拿到 machine 前先占着 gate，过了 gate 这里就不会等
    fcntl.flock(gate, fcntl.LOCK_UN)
    sim = ""

if mode == "sim":
    sims = [open(f"{root}/sim{n}", "a+") for n in range(pool)]
    free = next((n for n in range(pool) if take(sims[n])), None)
    if free is None:
        # 等任一台空出：每台一个线程阻塞在 flock 上，先拿到的算数，其余拿到后马上放掉
        print("排队：%d 台模拟器都在用\n  %s" % (pool, "\n  ".join(map(note, sims))), file=sys.stderr, flush=True)
        won, pick, result = threading.Event(), threading.Lock(), []

        def claim(n):
            fcntl.flock(sims[n], fcntl.LOCK_EX)
            with pick:
                if result:
                    fcntl.flock(sims[n], fcntl.LOCK_UN)
                    return
                result.append(n)
            won.set()

        for n in range(pool):
            threading.Thread(target=claim, args=(n,), daemon=True).start()
        won.wait()
        free = result[0]
    sim = str(free)
    held.append(sims[free])

for f in held:
    mark(f, f"{time.strftime('%H:%M:%S')} 起  {me}")

child = subprocess.Popen(cmd, env=dict(os.environ, CUEPAD_SIM=sim))


def tree(root):
    """root 与它的全部后代：swift test 的测试宿主、xcodebuild 的编译器各自另起进程组，按组结束会漏下它们。"""
    children = {}
    for line in subprocess.run(["ps", "-axo", "pid=,ppid="], capture_output=True, text=True).stdout.splitlines():
        pid, ppid = map(int, line.split())
        children.setdefault(ppid, []).append(pid)
    found, todo = [], [root]
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
    code = child.wait(timeout=limit)
except subprocess.TimeoutExpired:
    print(f"任务跑了 {limit // 60} 分钟还没完，连同它起的进程一起结束", file=sys.stderr, flush=True)
    signal_tree(signal.SIGTERM)
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        signal_tree(signal.SIGKILL)
    code = 124
for f in held:
    mark(f, "")
sys.exit(128 - code if code < 0 else code)
PY
)" "$HOLD_LIMIT" "$SIM_POOL" "/tmp/cuepad-xc-$UID" "$APPLE_DIR/.derived/xc.lock" "$@"
}
