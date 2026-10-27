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
        os.remove(path)
        time.sleep(5)
    return m, {}


SCENES = {"files": scene_files}
