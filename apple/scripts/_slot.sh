# shellcheck shell=bash
# 全机重活排队：编译、测试、截图、性能测量同一时刻最多 SLOTS 个。并发再多机器就过载、个个都慢
# （实测 Mac 增量编译单独约 11 秒，9 个以上同时跑时 5 分半）。
# 槽位是 /tmp/cuepad-slots-<uid>/<号> 上的 flock：内核在持有进程退出时释放，崩了也不留死锁。
# 持有者把 CUEPAD_SLOT=<号> 传给子进程：脚本再调脚本不重复排队，模拟器按槽号取（_sim.sh）。
# 同一个检出先排自己的锁（<检出>/apple/.derived/xc.lock）再排槽：同一产物目录上的两个 xcodebuild 会抢构建数据库、互相覆盖产物。
# 一次最多占 SLOT_HOLD_LIMIT 秒，超了整组进程结束，防止卡死的任务一直占着。
# 用法：脚本开头 slot_enter <one|all> "$0" "$@"。one 占任一空槽；all 按号依次占满（性能测量独占机器，槽号记 0）。

SLOTS=3
SLOT_HOLD_LIMIT=1800

slot_enter() {
  [ -z "${CUEPAD_SLOT:-}" ] || return 0
  mkdir -p "$APPLE_DIR/.derived"
  exec python3 -c "$(cat <<'PY'
import fcntl, os, signal, subprocess, sys, threading, time

slots, limit, own, need, *cmd = sys.argv[1:]
slots, limit = int(slots), int(limit)
root = f"/tmp/cuepad-slots-{os.getuid()}"
os.makedirs(root, exist_ok=True)
files = [open(f"{root}/{n}", "a+") for n in range(slots)]

me = f"pid {os.getpid()}  {os.getcwd()}  {os.path.basename(cmd[0])} {' '.join(cmd[1:3])}"


def mark(f, text):
    f.truncate(0)
    f.write(text)
    f.flush()


checkout = open(own, "a+")
try:
    fcntl.flock(checkout, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    checkout.seek(0)
    print(f"排队：这个检出的上一个任务还在跑\n  {checkout.read().strip()}", file=sys.stderr, flush=True)
    fcntl.flock(checkout, fcntl.LOCK_EX)
mark(checkout, f"{time.strftime('%H:%M:%S')} 起排槽  {me}")


def take(n, block):
    try:
        fcntl.flock(files[n], fcntl.LOCK_EX | (0 if block else fcntl.LOCK_NB))
        return True
    except BlockingIOError:
        return False


def say_waiting():
    lines = []
    for f in files:
        f.seek(0)
        lines.append(f.read().strip() or "?")
    print("排队：%d 个槽都占着，空出一个就开始\n  %s" % (slots, "\n  ".join(lines)), file=sys.stderr, flush=True)


if need == "all":
    held = list(range(slots))
    waited = False
    for n in held:
        if not take(n, False):
            if not waited:
                say_waiting()
                waited = True
            take(n, True)
else:
    free = next((n for n in range(slots) if take(n, False)), None)
    if free is None:
        # 等任一槽空出：每个槽一个线程阻塞在 flock 上，先拿到的算数，其余拿到后马上放掉
        say_waiting()
        won, pick, result = threading.Event(), threading.Lock(), []

        def wait(n):
            take(n, True)
            with pick:
                if result:
                    fcntl.flock(files[n], fcntl.LOCK_UN)
                    return
                result.append(n)
            won.set()

        for n in range(slots):
            threading.Thread(target=wait, args=(n,), daemon=True).start()
        won.wait()
        free = result[0]
    held = [free]

for f in [files[n] for n in held] + [checkout]:
    mark(f, f"{time.strftime('%H:%M:%S')} 起  {me}")

# 子进程自成一组：超时与转发的信号整组送达（xcodebuild 起的编译器、测试宿主一起结束）
child = subprocess.Popen(cmd, env=dict(os.environ, CUEPAD_SLOT=str(held[0])), start_new_session=True)


def forward(sig, _):
    try:
        os.killpg(child.pid, sig)
    except ProcessLookupError:
        pass


for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, forward)
try:
    code = child.wait(timeout=limit)
except subprocess.TimeoutExpired:
    print(f"占槽超过 {limit // 60} 分钟，结束这一组进程", file=sys.stderr, flush=True)
    os.killpg(child.pid, signal.SIGTERM)
    try:
        child.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(child.pid, signal.SIGKILL)
    code = 124
for f in [files[n] for n in held] + [checkout]:
    mark(f, "")
sys.exit(128 - code if code < 0 else code)
PY
)" "$SLOTS" "$SLOT_HOLD_LIMIT" "$APPLE_DIR/.derived/xc.lock" "$@"
}
