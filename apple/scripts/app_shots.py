"""一次调用拍一批：解析 xc.sh shot|rec|run 的图清单，逐张拍、一张失败记下继续。"""
import re
import subprocess
from typing import NamedTuple

from app_env import Failed, die

USAGE = "每张写成 [图.png] [-- 启动参数…]，多张用单独的 , 隔开；启动参数一律放在 -- 之后"
NAME_WIDTH = 80


class Shot(NamedTuple):
    out: str
    args: list


def parse(cmd, platform, derived, tokens):
    """[图.png] [-- 启动参数…] , … → 每张的输出路径与启动参数。没写路径的放 <产物目录>/<shot|rec>-<平台>/<各启动参数的值连起来>.<png|mov>。"""
    groups = [[]]
    for token in tokens:
        groups.append([]) if token == "," else groups[-1].append(token)
    shots, names = [], {}
    for group in groups:
        head, args = (group[:group.index("--")], group[group.index("--") + 1:]) if "--" in group else (group, [])
        if len(head) > 1 or (head and head[0].startswith("-")):
            die(USAGE)
        if cmd == "run" and (head or len(groups) > 1):
            die("run 只起一个实例，不带图路径与 ,")
        out = head[0] if head else None
        if not out:
            name = "-".join(re.sub(r"\W+", "_", v) for v in args if not v.startswith("-") and v != "YES")[:NAME_WIDTH] or "default"
            names[name] = names.get(name, 0) + 1
            out = f"{derived}/{cmd}-{platform}/{name}{'' if names[name] == 1 else f'-{names[name]}'}.{'mov' if cmd == 'rec' else 'png'}"
        shots.append(Shot(out, args))
    if len({s.out for s in shots}) < len(shots):
        die("有几张的图路径重了")
    return shots


def batch(shots, take):
    """逐张 take(shot)：成功打印路径，失败（Failed、外部命令非零）记下继续，最后列出失败的并以 1 退出。"""
    failed = []
    for shot in shots:
        try:
            take(shot)
            print(shot.out, flush=True)
        except (Failed, subprocess.CalledProcessError):
            failed.append(shot.out)
    if failed:
        die(f"{len(failed)}/{len(shots)} 张失败：" + "、".join(failed))
