"""sync-bench.py 的边界场景：断网（M5）、限流（M7）、写完马上进后台（M8），与撞版本探针（versions，不进总表）。
同 _sync_scenes.py：拿一次运行（两端已连通），按事件驱动，返回 {指标: [秒或次数…]}。
"""
import json, os, sqlite3, subprocess, time

from _sync_run import exe_of, kind
from _sync_scenes import arrived, by_id, last, settled, writes
from app_env import isolated_env


def scene_offline(run, args):
    """M5 断网恢复：offline [断网秒=30] [次数=2] [path|nopath]。只有手机（B）连 iCloud 的请求失败、门铃断开（CloudOutage）；
    断着时手机对 Cue 说 3 句（积压待发）、Mac 的 Cue 说 3 句（积压待收）。恢复（path：同真断网，路径监视器报一次网络回来）后量
    第一次成功（同步状态离开离线）、积压发完（3 句都已发出）、收完（3 句都入库、上屏）、说的 3 句都有回执。"""
    down, times = float(args[0]) if args else 30, int(args[1]) if len(args) > 1 else 2
    path = (args[2] if len(args) > 2 else "path") == "path"
    a, b = run.a, run.b
    label = f"断网 {down:g} 秒{'' if path else '（路径不变）'}"
    m = run.metrics
    for i in range(times):
        t = b.send("offline"); b.wait(kind("offline"), 30, after=t)
        began = time.time()
        said = writes(b, [f"say off{i}-{k}" for k in range(3)], 3, "you", sent=False)
        told = writes(a, ["cue 3"], 3, "cue")
        time.sleep(max(0, began + down - time.time()))
        on = {"t": b.send("online path" if path else "online")}
        ok = b.wait(lambda e: e["e"] == "sync-status" and e["s"] != "offline", 120, after=on["t"])
        sent = [b.wait(by_id("msg-accepted", w["id"]), 180) for w in said]
        got = [b.wait(arrived(w["id"]), 180) for w in told]
        shown = [b.wait(by_id("msg-shown", w["id"]), 30) for w in told]
        receipts = [b.wait(by_id("msg-delivered", w["id"]), 180) for w in said]
        m.span(f"{label}·恢复→第一次成功", on, ok)
        m.span(f"{label}·恢复→积压发完", on, last(sent))
        m.span(f"{label}·恢复→积压收完（入库）", on, last(got))
        m.span(f"{label}·恢复→积压收完（上屏）", on, last(shown))
        m.span(f"{label}·恢复→说的话都有回执", on, last(receipts))
        time.sleep(10)
    return m, {}


def scene_throttle(run, args):
    """M7 限流：throttle [限流秒=20] [Retry-After 秒=8] [次数=2]。只在模拟云里：云在窗口内按 CloudKit 的设备限流回（`SharedCloud.admit`：
    到了服务器的回 429 带 Retry-After，那之前再来的当场拒，记 early）；窗口里手机对 Cue 说一句（要重试的上传）。
    按云记下的每个请求数：窗口内各实例发了几次拉取、上传，几次没守自己收到过的 Retry-After（这个进程之前被拒时告诉它的那一刻之前又发；
    别的进程刚被拒、这台已被限着而它不知道的，不算），解除到各自第一拉成功、说的那句已发出各多久。"""
    down, wait, times = float(args[0]) if args else 20, float(args[1]) if len(args) > 1 else 8, int(args[2]) if len(args) > 2 else 2
    if run.cloud != "sim": raise SystemExit("throttle 只在模拟云里跑（真 CloudKit 的限流会拖累这台的正式版）")
    cloud, label = f"{run.out}/cloud", f"限流 {down:g} 秒（Retry-After {wait:g}）"
    m = run.metrics
    for i in range(times):
        began = time.time()
        json.dump({"until": began + down, "retryAfter": wait}, open(f"{cloud}/throttle.json", "w"))
        time.sleep(3)
        said = writes(run.b, [f"say throttle{i}"], 1, "you", sent=False)
        time.sleep(max(0, began + down - time.time()))
        free = {"t": began + down}
        sent = run.b.wait(by_id("msg-accepted", said[0]["id"]), 90) if said else None
        time.sleep(5)
        with sqlite3.connect(f"{cloud}/cloud.sqlite") as db:
            rows = db.execute("SELECT t, pid, kind, result, wait FROM requests WHERE t >= ? ORDER BY t", (began,)).fetchall()
        for inst, role in ((run.a, "Mac"), (run.b, "手机")):
            mine = [r for r in rows if r[1] == inst.pid]
            inside = [r for r in mine if r[0] < free["t"]]
            m[f"{label}·{role}·窗口内拉取（次）"].append(sum(r[2] == "fetch" for r in inside))
            m[f"{label}·{role}·窗口内上传（次）"].append(sum(r[2] == "upload" for r in inside))
            m[f"{label}·{role}·没守 Retry-After（次）"].append(ignored(mine))
            ok = next((r[0] for r in mine if r[2] == "fetch" and r[3] == "ok" and r[0] >= free["t"]), None)
            m.span(f"{label}·{role}·解除→第一拉成功", free, ok and {"t": ok})
        m.span(f"{label}·解除→窗口里说的话已发出", free, sent)
        os.remove(f"{cloud}/throttle.json")
        time.sleep(10)
    return m, {}


def ignored(requests):
    """一个进程的请求里，发在它自己收到过的 Retry-After 到期之前的几个（同一时刻一起被拒的几个并发请求不算）。"""
    refusals = [(t, t + wait) for t, _, _, _, wait in requests if wait is not None]
    return sum(1 for t, *_ in requests if any(at < t - 0.05 and t < until - 0.05 for at, until in refusals))


def scene_bgflush(run, args):
    """M8 写完马上进后台：bgflush [次数=8]。手机对 Cue 说一句、紧接着走进后台的收尾（`prepareForBackground`：传完、门铃按完才断开）；
    量写下→已发出、进后台→收尾完、写下→Mac 入库，再回前台等下一次。"""
    times, (a, b) = int(args[0]) if args else 8, (run.a, run.b)
    m = run.metrics
    for i in range(times):
        t0 = b.send(f"say bg{i}")
        t1 = b.send("bg")
        w = b.wait(kind("msg-write", "you"), 10, after=t0 - 0.5)
        done = b.wait(kind("bg-done"), 60, after=t1 - 0.01)
        m.span("进后台收尾·写下→已发出", w, w and b.wait(by_id("msg-accepted", w["id"]), 60))
        m.span("进后台收尾·进后台→收尾完", {"t": t1}, done)
        m.span("进后台收尾·写下→Mac 入库", w, w and a.wait(arrived(w["id"]), 60))
        t = b.send("fg"); b.wait(kind("fg-done"), 30, after=t - 0.01)
        time.sleep(6)
    return m, {}


def scene_versions(run, args):
    """撞版本探针（不进总表）：versions [命令行改几次=150]。A 用 App 的库紧循环改一张卡（`churn`），同时命令行（这个检出的 cuepad，同一个隔离库）逐条改同一张；
    库里加一个审计触发器记下每次提交的版本，数提交后版本不比上一版大的次数（其中前后两版来自不同进程的另记）。
    同一行的新版本一定比旧的大由库层的版本触发器守着（`CueStore.guards`），应是 0。"""
    count, a = int(args[0]) if args else 150, run.a
    t = a.send("card-new")
    card = a.wait(kind("card"), 10, after=t - 0.01)["id"]
    library = f"{a.home}/library"
    with sqlite3.connect(f"{library}/cuepad.db") as db:
        db.executescript("""
          CREATE TABLE IF NOT EXISTS benchAudit(seq INTEGER PRIMARY KEY, v INTEGER, body TEXT);
          CREATE TRIGGER IF NOT EXISTS benchAudit AFTER UPDATE OF modifiedAt ON cards BEGIN INSERT INTO benchAudit(v, body) VALUES (new.modifiedAt, new.body); END;
          """)
    env = isolated_env(library, a.sockets)
    assert os.path.realpath(env["CUEPAD_LIBRARY_DIR"]).startswith(os.path.realpath(run.out)), env["CUEPAD_LIBRARY_DIR"]  # 命令行只碰这次的隔离库
    cli = f"{os.path.dirname(exe_of(run.checkout))}/../Helpers/cuepad"
    a.send(f"churn {card}")
    for i in range(count):
        subprocess.run([cli, "card", "edit", card, "--body", f"cli-{i}"], env=env, check=True, capture_output=True)
    t = a.send("churn-stop")
    churned = a.wait(kind("churned"), 30, after=t - 0.01)
    with sqlite3.connect(f"{library}/cuepad.db") as db:
        rows = db.execute("SELECT v, body FROM benchAudit ORDER BY seq").fetchall()
    effective = []  # 同一正文连着的几次是同一次提交里的几步，取其中最大的版本
    for v, body in rows:
        if effective and effective[-1][1] == body: effective[-1] = (max(effective[-1][0], v), body)
        else: effective.append((v, body))
    stale = [(p, n) for p, n in zip(effective, effective[1:]) if n[0] <= p[0]]
    m = run.metrics
    m["撞版本·提交后版本不比上一版大（次）"].append(len(stale))
    m["撞版本·其中跨进程（次）"].append(sum(p[1][:3] != n[1][:3] for p, n in stale))
    return m, {"撞版本": {"App 写": churned["writes"] if churned else None, "命令行写": count, "提交": len(effective)}}


EDGES = {"offline": scene_offline, "throttle": scene_throttle, "bgflush": scene_bgflush, "versions": scene_versions}
