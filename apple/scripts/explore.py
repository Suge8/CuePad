#!/usr/bin/env python3
"""偶发的主线程卡死找法：起一份 iPhone 隔离实例（xc.sh run），在 Cue 页、看板、会话页之间按种子随机点、滑（axe，按 UDID 投递，不动前台），
App 里的看守（MainThreadWatch：主线程一轮事件循环超过 1 秒）在库目录的 Diagnostics 写下 freeze 那份时，停手、连取三次进程的样本与一张截图。
用法：xc.sh explore [种子=1] [秒=600] [-- 启动参数…]（默认 -CuePadDemo YES -CuePadLongChat YES）
  种子写成一份记录（apple/.derived/explore/<种子>.log）的路径时照它回放：同样的动作、同样的间隔；从同一个画面起才对得上。
  一个种子跑 SEED_SECONDS 秒，没卡住换下一个种子（种子 +1），直到总时长。坐标按 iPhone 17（402×874 点）取自截图：axe describe-ui 读不到 SwiftUI 的元素。
  CUEPAD_EXPLORE_WEIGHTS="scroll=40,edge back=0" 按动作名改权重（盯一页时调低离开它的动作，名字见 ACTIONS）。
产物在 apple/.derived/explore/：每步一行的记录（种子、步、时刻、动作）、卡住时的 hang-<种子>-<步>-<n>.sample 与截图。
退出码：0 没卡住；1 卡住了（样本已取，实例留给你接着看，xc.sh stop 收）；3 实例自己没了（崩溃报告见 docs/diagnose.md）。
"""
import glob, json, os, random, subprocess, sys, time

APPLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = f"{APPLE}/.derived/explore"
W, H = 402, 874
SEED_SECONDS = 150


def rx(rng, a, b):
    return round(rng.uniform(a, b))


# (权重, 名字, 生成 axe 参数)
ACTIONS = [
    (14, "tap rail", lambda r: ("tap", "-x", rx(r, 15, 50), "-y", rx(r, 130, 760))),
    (8, "tap sidebar button", lambda r: ("tap", "-x", 38, "-y", 90)),
    (8, "tap header center", lambda r: ("tap", "-x", rx(r, 120, 330), "-y", rx(r, 75, 105))),
    (4, "tap header right", lambda r: ("tap", "-x", rx(r, 350, 385), "-y", 90)),
    (18, "tap content", lambda r: ("tap", "-x", rx(r, 70, 390), "-y", rx(r, 120, 760))),
    (6, "tap composer", lambda r: ("tap", "-x", rx(r, 90, 360), "-y", rx(r, 790, 815))),
    (3, "tap plus", lambda r: ("tap", "-x", 39, "-y", 803)),
    (16, "scroll", lambda r: (lambda y0, d: ("swipe", "--start-x", rx(r, 150, 350), "--start-y", y0, "--end-x", rx(r, 150, 350),
                                             "--end-y", max(60, min(840, y0 + d)), "--duration", r.choice([0.1, 0.2, 0.4])))(rx(r, 200, 700), r.choice([-1, 1]) * rx(r, 150, 500))),
    (7, "edge back", lambda r: ("swipe", "--start-x", 5, "--start-y", rx(r, 300, 600), "--end-x", rx(r, 250, 380), "--end-y", rx(r, 300, 600), "--duration", 0.4, "--delta", 5)),
    (4, "swipe row", lambda r: (lambda y: ("swipe", "--start-x", rx(r, 250, 380), "--start-y", y, "--end-x", rx(r, 40, 150), "--end-y", y, "--duration", 0.2))(rx(r, 150, 750))),
    (3, "pull down", lambda r: ("swipe", "--start-x", rx(r, 150, 300), "--start-y", rx(r, 150, 250), "--end-x", rx(r, 150, 300), "--end-y", rx(r, 500, 700), "--duration", 0.3)),
    (4, "type", lambda r: ("type", r.choice(["你好", "看看进展", "ok", "继续"]))),
    (3, "escape", lambda r: ("key", 41)),
    (2, "tap status bar", lambda r: ("tap", "-x", rx(r, 100, 300), "-y", 15)),
]


def weights():
    actions = ACTIONS
    for item in filter(None, os.environ.get("CUEPAD_EXPLORE_WEIGHTS", "").split(",")):
        key, value = item.rsplit("=", 1)
        actions = [(float(value) if n == key else w, n, m) for w, n, m in actions]
    return actions


def explore(pid, udid, diag, seed, seconds, replay):
    """跑一个种子：0 没卡住，1 卡住（已取样本），3 实例没了。"""
    rng, actions = random.Random(seed), weights()
    total = sum(w for w, _, _ in actions)
    seen = set(glob.glob(f"{diag}/*freeze*"))
    with open(f"{OUT}/{seed}{'-replay' if replay else ''}.log", "a") as log:
        start, step = time.time(), 0
        while time.time() - start < seconds and (replay is None or step < len(replay)):
            if subprocess.run(["kill", "-0", pid], capture_output=True).returncode != 0:
                print(json.dumps({"seed": seed, "step": step, "event": "app gone"}), file=log, flush=True)
                print(f"实例 {pid} 没了（种子 {seed} 第 {step} 步）")
                return 3
            if replay is not None:
                name, args = replay[step]["action"], replay[step]["args"]
                pause = replay[step + 1]["t"] - replay[step]["t"] if step + 1 < len(replay) else 0.3
            else:
                r, name = rng.uniform(0, total), actions[-1][1]
                for w, n, make in actions:
                    r -= w
                    if r <= 0:
                        name, args = n, make(rng)
                        break
                pause = rng.uniform(0.05, 0.6)
            print(json.dumps({"seed": seed, "step": step, "t": round(time.time() - start, 2), "action": name, "args": args}, ensure_ascii=False), file=log, flush=True)
            began = time.time()
            subprocess.run(["axe", *map(str, args), "--udid", udid], capture_output=True, timeout=30)
            time.sleep(max(0, pause - (time.time() - began)) if replay is not None else pause)
            step += 1
            fresh = sorted(set(glob.glob(f"{diag}/*freeze*")) - seen)
            if fresh:
                for n in range(3):
                    subprocess.run(["sample", pid, "2", "-file", f"{OUT}/hang-{seed}-{step}-{n}.sample"], capture_output=True)
                subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", f"{OUT}/hang-{seed}-{step}.png"], capture_output=True)
                print(json.dumps({"seed": seed, "step": step, "event": "freeze", "files": fresh}), file=log, flush=True)
                print(f"卡住：种子 {seed} 第 {step} 步，记录 {fresh}；样本与截图在 {OUT}/hang-{seed}-{step}-*")
                return 1
    print(f"种子 {seed}：{step} 步没卡住")
    return 0


def main(argv):
    xc, rest = argv[0], argv[1:]
    launch = rest[rest.index("--") + 1:] if "--" in rest else ["-CuePadDemo", "YES", "-CuePadLongChat", "YES"]
    rest = rest[:rest.index("--")] if "--" in rest else rest
    seed_arg = rest[0] if rest else "1"
    seconds = float(rest[1]) if len(rest) > 1 else 600
    os.makedirs(OUT, exist_ok=True)
    replay = [json.loads(line) for line in open(seed_arg) if '"action"' in line] if os.path.exists(seed_arg) else None
    seed = int(replay[0]["seed"]) if replay else int(seed_arg)
    env = dict(os.environ, CUEPAD_RUN_SECONDS=str(int(seconds) + 300))
    run = subprocess.run([xc, "run", "ios", "--", *launch], capture_output=True, text=True, env=env)
    lines = [line.split() for line in run.stdout.splitlines() if line.split() and line.split()[0].isdigit()]
    if run.returncode != 0 or not lines:
        sys.stderr.write(run.stdout + run.stderr)
        return run.returncode or 1
    pid, udid = lines[-1][0], lines[-1][1]
    diag = os.path.join(os.environ.get("CUEPAD_SHOT_LIBRARY", f"{APPLE}/.derived/library-ios"), "Diagnostics")
    print(f"实例 {pid}（模拟器 {udid}），记录在 {OUT}")
    deadline = time.time() + seconds
    while time.time() < deadline:
        status = explore(pid, udid, diag, seed, min(SEED_SECONDS, deadline - time.time()), replay)
        if status:
            return status
        if replay is not None:
            break
        seed += 1
    subprocess.run([xc, "stop"], capture_output=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
