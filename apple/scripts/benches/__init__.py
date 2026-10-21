"""记忆基准的共用部分：下载、时刻、把会话排成一句一条、分层抽题；各家的读入与判分提示在同目录的各自文件里。"""
import collections
import random
import time
import urllib.request
from datetime import datetime
from pathlib import Path

SEED = 42
TOTAL = 100
# 一条会话里相邻两句隔这么多秒（数据只给会话的开始时刻，或连时刻都不给）
TURN_GAP = 30


def fetch(url: str, path: Path):
    """下载到 path（缺时才下）；HF 偶尔断连，重试几次。"""
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    for attempt in range(6):
        try:
            urllib.request.urlretrieve(url, part)
            part.rename(path)
            return
        except OSError:
            if attempt == 5:
                raise
            time.sleep(3 * (attempt + 1))


def stamp(text: str, form: str) -> float:
    """数据里的时刻按本机时区读成 epoch 秒，同 Cue 信封的日历。"""
    return datetime.strptime(text, form).timestamp()


def sessions_log(sessions: list) -> list:
    """[(开始时刻 epoch, [(作者, 正文)…])…] 按开始时刻排好，一句一条：会话开始时刻起每句隔 TURN_GAP 秒，且严格递增。"""
    log, last = [], float("-inf")
    for start, turns in sorted(sessions, key=lambda pair: pair[0]):
        for index, (author, text) in enumerate(turns):
            last = max(start + index * TURN_GAP, last + 1)
            log.append([author, last, text])
    return log


class Bench:
    """一家基准：读官方数据成一条条题（dict，至少有 id），分层、写成题目行、判分。"""
    name = title = strata = setup = judging = ""

    def __init__(self, data: Path):
        self.data = data

    def entries(self) -> list: ...
    def stratum(self, entry: dict) -> str: ...
    def ident(self, entry: dict) -> str: return entry["id"]
    def line(self, entry: dict) -> dict: ...
    def prompt(self, result: dict) -> str: ...
    def passed(self, result: dict, verdict: str) -> bool: ...

    def sample(self, entries: list, seed: int = SEED, exclude: frozenset = frozenset()) -> list:
        """按层按比例抽 TOTAL 题，余数按最大余数法分；层内与层的先后都用固定种子。各层题数按全集算，`exclude` 里的题不抽。"""
        layers = collections.defaultdict(list)
        for entry in entries:
            layers[self.stratum(entry)].append(entry)
        quota = {name: TOTAL * len(items) / len(entries) for name, items in layers.items()}
        counts = {name: int(q) for name, q in quota.items()}
        for name in sorted(quota, key=lambda n: (-(quota[n] - counts[n]), n))[: TOTAL - sum(counts.values())]:
            counts[name] += 1
        rng = random.Random(seed)
        picked = []
        for name in sorted(layers):
            picked += rng.sample(sorted((e for e in layers[name] if self.ident(e) not in exclude), key=self.ident), counts[name])
        return picked
