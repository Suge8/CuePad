#!/usr/bin/env python3
"""性能的新旧前后对比：两个检出各构建一次，旧新交替跑同一条 perf 命令，每轮跑完立刻打一行，最后列两边中位数的对比表。前台阻塞到结束，不用另外轮询。

用法：xc.sh perf ab <旧检出> <新检出> <轮数> [idle|launch] <mac|ios> [次数] [参数…]
  后面就是 `xc.sh perf` 自己的参数（perf-mac.sh、perf-ios.sh、perf-idle.sh、perf-launch.sh 的头注释），如：
    xc.sh perf ab ../CuePad ./ 3 mac 1 -CuePadInteractOnly 会话页       单次交互
    xc.sh perf ab ../CuePad ./ 4 idle mac 1 30                           静置（每次 1 个进程、量 30 秒）
    xc.sh perf ab ../CuePad ./ 5 launch mac 1                            冷启动
  <次数> 是每轮里每个检出自己跑几遍；轮与轮交替先后（旧新、新旧……），先后顺序的系统偏差互相抵消。
  每个检出用自己的 xc.sh 跑（排队、锁、构建照它的规则），结果行读它留在 apple/.derived-perf/Build 的 idle.jsonl、launch.jsonl、interact.jsonl。
  以指令数与唤醒为准（机器忙时墙钟、CPU 时间、能耗会被别的进程拖歪），每轮行里带当时的 1 分钟负载；表里每格是中位数与各次的范围，两边范围重叠的标「≈」，别当成改善或退步。
  带 -CuePadForeground YES 的前台测量，交互超预算时 perf mac 以 1 退出，这里照样往下跑（预算判断看各轮自己的表，对比只看数）。
每轮的完整输出与全部原始行在 /tmp/cuepad-perf-ab/<时刻>/。
"""
import json
import os
import statistics as st
import subprocess
import sys
import time
from datetime import datetime

OUT_ROOT = "/tmp/cuepad-perf-ab"
ROWS = {"idle": "idle.jsonl", "launch": "launch.jsonl", "interact": "interact.jsonl"}
LAUNCH_PREFIX = "LAUNCH-ROW "
# 主要看的指标（每轮行与表里先列、interact 只列这些）；idle 与 launch 的表里其余数值指标跟在后面
PRIMARY = {
    "idle": ["instructionsM", "wakeupsPerSec", "cpuMs", "energyMJ"],
    "launch": ["interactiveMainM", "interactiveAllM", "contentMainM", "interactive"],
    "interact": ["clickInstructionsM", "instructionsM", "clickMs"],
}


def die(message):
    print(message, file=sys.stderr)
    sys.exit(2)


def parse(argv):
    if len(argv) < 4 or not argv[2].isdigit():
        die(__doc__)
    old, new, rounds, args = os.path.abspath(argv[0]), os.path.abspath(argv[1]), int(argv[2]), argv[3:]
    kind = args[0] if args[0] in ("idle", "launch") else "interact"
    if (args[1:] if kind != "interact" else args)[:1] not in (["mac"], ["ios"]):
        die(__doc__)
    platform = args[1] if kind != "interact" else args[0]
    for checkout in (old, new):
        if not os.access(f"{checkout}/apple/scripts/xc.sh", os.X_OK):
            die(f"{checkout} 不是 CuePad 检出（没有 apple/scripts/xc.sh）")
    return old, new, rounds, args, kind, platform


def commit(checkout):
    git = ["git", "-C", checkout]
    head = subprocess.run([*git, "log", "-1", "--format=%h %s"], capture_output=True, text=True).stdout.strip()
    dirty = subprocess.run([*git, "status", "--porcelain", "--untracked-files=no"], capture_output=True, text=True).stdout.strip()
    return head[:60] + ("（有未提交改动）" if dirty else "")


def xc(checkout, args, log):
    started = time.monotonic()
    with open(log, "w") as out:
        status = subprocess.run([f"{checkout}/apple/scripts/xc.sh", *args], stdout=out, stderr=subprocess.STDOUT).returncode
    return status, time.monotonic() - started


def fail(checkout, log, status):
    print(f"\n{checkout} 的 xc.sh 以 {status} 退出，输出末尾（全文 {log}）：", file=sys.stderr)
    print("".join(open(log).readlines()[-30:]), file=sys.stderr)
    sys.exit(1)


def read_rows(checkout, kind):
    rows = []
    for line in open(f"{checkout}/apple/.derived-perf/Build/{ROWS[kind]}"):
        line = line.removeprefix(LAUNCH_PREFIX).strip()
        if line:
            rows.append(json.loads(line))
    return rows


def numbers(row):
    return {k: v for k, v in row.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}


def collect(rows, kind):
    """{(项, 指标): [各次的值]}：项只有 interact 有（库与交互名），idle、launch 是 ""。"""
    found = {}
    for row in rows:
        item = " ".join(str(row[k]) for k in ("库", "name") if k in row) if kind == "interact" else ""
        for metric, value in numbers(row).items():
            found.setdefault((item, metric), []).append(value)
    return found


def brief(rows, kind):
    """一轮里这个检出的主要指标：交互各项的中位数相加，其余直接取中位数。"""
    found = collect(rows, kind)
    parts = []
    for metric in PRIMARY[kind]:
        medians = [st.median(v) for (_, m), v in found.items() if m == metric]
        if medians:
            parts.append(f"{metric} {sum(medians):g}")
    return "  ".join(parts)


def cell(values):
    return f"{st.median(values):g} ({min(values):g}–{max(values):g})"


def table(old_rows, new_rows, kind):
    old, new = collect(old_rows, kind), collect(new_rows, kind)
    order = [k for k in old if k in new]
    primary = PRIMARY[kind]
    items = list(dict.fromkeys(item for item, _ in order))
    shown = sorted((k for k in order if k[1] in primary or kind != "interact"),
                   key=lambda k: (items.index(k[0]), primary.index(k[1]) if k[1] in primary else len(primary)))
    width = max((len(" ".join(filter(None, k))) for k in shown), default=8) + 2
    print(f"\n{'指标（中位数与各次范围）':<{width}}{'旧':<30}{'新':<30}Δ")
    for key in shown:
        a, b = st.median(old[key]), st.median(new[key])
        delta = f"{(b - a) / a * 100:+.1f}%" if a else f"{b - a:+g}"
        overlap = "  ≈" if min(old[key]) <= max(new[key]) and min(new[key]) <= max(old[key]) else ""
        print(f"{' '.join(filter(None, key)):<{width}}{cell(old[key]):<30}{cell(new[key]):<30}{delta}{overlap}")


def main(argv):
    old, new, rounds, args, kind, platform = parse(argv)
    out = f"{OUT_ROOT}/{datetime.now():%m%d-%H%M%S}"
    os.makedirs(out)
    sides = {"旧": old, "新": new}
    print(f"perf {' '.join(args)}，交替 {rounds} 轮；输出 {out}")
    for name, checkout in sides.items():
        print(f"  {name} = {checkout}（{commit(checkout)}）")
    for name, checkout in sides.items():
        status, seconds = xc(checkout, ["build-perf", platform], f"{out}/build-{name}.log")
        if status:
            fail(checkout, f"{out}/build-{name}.log", status)
        print(f"构建 {name} {seconds:.0f} 秒", flush=True)
    results = {"旧": [], "新": []}
    for i in range(rounds):
        for name in ("旧", "新") if i % 2 == 0 else ("新", "旧"):
            log = f"{out}/round{i + 1}-{name}.log"
            status, seconds = xc(sides[name], ["perf", *args], log)
            # 前台的单次交互超预算时 perf mac 以 1 退出，行照样是全的；别的非零都是没量完
            overBudget = status == 1 and kind == "interact" and "-CuePadForeground" in args
            rows = read_rows(sides[name], kind) if status == 0 or overBudget else []
            if not rows:
                fail(sides[name], log, status)
            results[name] += rows
            print(f"[{i + 1}/{rounds}] {name} {seconds:.0f} 秒  负载 {os.getloadavg()[0]:.0f}  {brief(rows, kind)}", flush=True)
    json.dump(results, open(f"{out}/rows.json", "w"), ensure_ascii=False, indent=1)
    table(results["旧"], results["新"], kind)


if __name__ == "__main__":
    main(sys.argv[1:])
