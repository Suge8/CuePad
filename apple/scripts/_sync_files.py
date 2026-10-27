"""sync-bench.py 的带文件场景：手机（B）同一刻写下三样——带大文件的灵感、只有字的灵感、对 Cue 说的一句——Mac（A）收，
量大文件挡不挡同一刻写下的别的（实现与打点见 SyncBench+Files.swift）。文件每轮现做一个（随机像素的无压缩 TIFF：
同一个文件第二轮就不再上传），传多久由模拟云按大小与速率算（LATENCY 的 assetUp、assetDown）。
"""
import os, struct, time

from _sync_run import OUT_ROOT, kind
from _sync_scenes import ROUND_LIMIT, arrived, by_id

FILES = f"{OUT_ROOT}/files"
FILE_LIMIT = 300  # 一轮里等文件到对端最多这么久


def make_file(path, megabytes):
    """megabytes MB 的无压缩 RGB TIFF（宽 4096），像素随机：ImageIO 认得，内容不重样。"""
    width = 4096
    height = (megabytes << 20) // (width * 3)
    size, entries, data_at = width * height * 3, 10, 8 + 2 + 10 * 12 + 4 + 6
    tags = [(256, 4, 1, width), (257, 4, 1, height), (258, 3, 3, data_at - 6), (259, 3, 1, 1), (262, 3, 1, 2),
            (273, 4, 1, data_at), (277, 3, 1, 3), (278, 4, 1, height), (279, 4, 1, size), (284, 3, 1, 1)]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"II*\0" + struct.pack("<I", 8) + struct.pack("<H", entries))
        for tag, kind_, count, value in tags:
            f.write(struct.pack("<HHI", tag, kind_, count) + (struct.pack("<HH", value, 0) if kind_ == 3 and count == 1 else struct.pack("<I", value)))
        f.write(struct.pack("<I", 0) + struct.pack("<HHH", 8, 8, 8))
        for _ in range(size >> 20): f.write(os.urandom(1 << 20))
        f.write(os.urandom(size & ((1 << 20) - 1)))
    return path


def card_new(id):
    return lambda e: e["e"] == "card-new" and e.get("id") == id


def scene_files(run, args):
    """files [轮数=6] [MB=50]：每轮手机同一刻写下三样，等文件到了 Mac 再下一轮。"""
    rounds, megabytes = int(args[0]) if args else 6, int(args[1]) if len(args) > 1 else 50
    a, b, m = run.a, run.b, run.metrics
    for i in range(rounds):
        path = make_file(f"{FILES}/{os.getpid()}-{i}.tiff", megabytes)
        t0 = b.send(f"burst f{i} {path}")
        burst = b.wait(kind("burst"), 60, after=t0 - 0.5)
        if not burst:
            m["同一刻写下·没写成（次）"].append(1)
            continue
        a.send(f"watch-file {burst['key']}")
        m["同一刻写下·存文件（写下之前）"].append(round(burst["stored"], 3))
        written = {"t": burst["at"]}
        say = b.wait(kind("msg-write", "you"), 10, after=t0 - 0.5)
        m.span("同一刻写下·只有字的灵感·写下→Mac 入库", written, a.wait(card_new(burst["text"]), ROUND_LIMIT * 3))
        m.span("同一刻写下·带文件的灵感·写下→Mac 入库", written, a.wait(card_new(burst["big"]), ROUND_LIMIT * 3))
        if say:
            m.span("同一刻写下·对 Cue 说·写下→Mac 入库", say, a.wait(arrived(say["id"]), ROUND_LIMIT))
            m.span("同一刻写下·对 Cue 说·全程（写下→已送达）", say, b.wait(by_id("msg-delivered", say["id"]), ROUND_LIMIT))
        m.span("同一刻写下·文件·写下→到 Mac", written, a.wait(lambda e: e["e"] == "file-arrived" and e.get("key") == burst["key"], FILE_LIMIT))
        for name, inst, direction in (("上传", b, "up"), ("下载", a, "down")):
            seen = [e for e in inst.events if e["e"] == "transfer" and e["key"] == burst["key"] and e["dir"] == direction]
            m[f"同一刻写下·文件·界面读到的{name}进度（次）"].append(len(seen))
            if seen and max(e["f"] for e in seen) < 1: m[f"同一刻写下·文件·{name}进度没到 1（次）"].append(1)
        os.remove(path)
        time.sleep(5)
    return m, {}


def scene_files_quota(run, args):
    """filesquota [轮数=2] [MB=50]（只在模拟云）：iCloud 空间满（模拟云拒收带文件的保存），手机同一刻写下三样；
    只有字的灵感与对 Cue 说的照常到 Mac、手机的同步状态不变，文件停在手机、界面读到"文件因空间不足停着"。"""
    if run.cloud != "sim": raise SystemExit("filesquota 只在模拟云")
    rounds, megabytes = int(args[0]) if args else 2, int(args[1]) if len(args) > 1 else 50
    a, b, m = run.a, run.b, run.metrics
    open(f"{run.out}/cloud/quota-full", "w").close()
    for i in range(rounds):
        path = make_file(f"{FILES}/{os.getpid()}-q{i}.tiff", megabytes)
        t0 = b.send(f"burst q{i} {path}")
        burst = b.wait(kind("burst"), 60, after=t0 - 0.5)
        if not burst:
            m["空间满·没写成（次）"].append(1)
            continue
        a.send(f"watch-file {burst['key']}")
        written = {"t": burst["at"]}
        say = b.wait(kind("msg-write", "you"), 10, after=t0 - 0.5)
        m.span("空间满·只有字的灵感·写下→Mac 入库", written, a.wait(card_new(burst["text"]), ROUND_LIMIT))
        if say: m.span("空间满·对 Cue 说·写下→Mac 入库", say, a.wait(arrived(say["id"]), ROUND_LIMIT))
        if i == 0: m.span("空间满·写下→手机读到文件停着", written, b.wait(lambda e: e["e"] == "files-over-quota" and e["v"], ROUND_LIMIT))
        if a.wait(lambda e: e["e"] == "file-arrived" and e.get("key") == burst["key"], 30): m["空间满·文件却到了 Mac（次）"].append(1)
        bad = [e["s"] for e in b.events if e["e"] == "sync-status" and e["t"] >= burst["at"] and e["s"] not in ("idle", "syncing")]
        if bad: m["空间满·手机同步状态变了（次）"].append(len(bad))
        os.remove(path)
    return m, {}


def scene_file_resume(run, args):
    """fileresume [MB=100]（只在真 CloudKit）：手机传大文件传到四成时被杀掉（SIGKILL），20 秒后再起：
    系统（cloudd）接着传的长期操作被接上，不从头再传。量重启→手机读到上传结束（从头再传要几十秒）、重启后第一次读到的进度、文件到 Mac。"""
    if run.cloud != "real": raise SystemExit("fileresume 只在真 CloudKit：模拟云的上传在进程里，杀掉就没了")
    megabytes = int(args[0]) if args else 100
    a, b, m = run.a, run.b, run.metrics
    path = make_file(f"{FILES}/{os.getpid()}-resume.tiff", megabytes)
    t0 = b.send(f"burst r {path}")
    burst = b.wait(kind("burst"), 60, after=t0 - 0.5)
    if not burst: m["长期操作·没写成（次）"].append(1); return m, {}
    key = burst["key"]
    a.send(f"watch-file {key}")
    up = lambda e: e["e"] in ("transfer", "transfer-end") and e.get("key") == key and e.get("dir") == "up"
    if not b.wait(lambda e: up(e) and e.get("f", 0) >= 0.4, 120): m["长期操作·没传到四成（次）"].append(1); return m, {}
    b.proc.kill(); b.proc.wait()
    time.sleep(20)
    restarted = {"t": b.start()}
    first = b.wait(lambda e: up(e) and e["t"] >= restarted["t"], 120)
    if first and "f" in first: m["长期操作·重启后第一次读到的进度（成）"].append(round(first["f"] * 10, 1))
    m.span("长期操作·重启→手机读到上传结束", restarted, b.wait(lambda e: e["e"] == "transfer-end" and e.get("key") == key and e["t"] >= restarted["t"], 120))
    m.span("长期操作·写下→文件到 Mac", {"t": burst["at"]}, a.wait(lambda e: e["e"] == "file-arrived" and e.get("key") == key, 120))
    os.remove(path)
    return m, {}


SCENES = {"files": scene_files, "filesquota": scene_files_quota, "fileresume": scene_file_resume}
