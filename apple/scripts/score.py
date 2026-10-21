#!/usr/bin/env python3
"""Cue 评测的成绩单：读几遍的输出目录（每个场景一份 <场景>.score.json，CueEvalScore 写），按套（短场景、长程、多日）
汇总判定的类别通过数与量化指标，比两组之间的差与每条判定的翻转。跑法、指标定义见 docs/verify.md「Cue 评测」。

  score.py RUN [RUN…] [--vs RUN [RUN…]]   一组是改前（或基线），--vs 后是改后；每个 RUN 是一遍的输出目录。
                                            写最后一个 RUN/score.md 并打印路径

写法同 bench.py 的报告：每一遍一列；两组时多出两组均值与差（改后 − 改前）、组内差（同一设置几遍之间最大减最小，看波动）与翻转。
"""
import argparse
import json
import statistics
from pathlib import Path

KINDS = ["结果", "问", "打扰", "工具", "接续", "记忆"]
SUITES = ["短场景", "长程", "多日"]
REASONS = ["参数校验退回", "对象找不到", "没有这个工具", "其他"]
# (行名, 从一遍的合计里取数)
METRICS = [
    ("醒来次数", lambda m: m["wakes"]),
    ("工具调用", lambda m: m["calls"]),
    ("每次醒来的调用", lambda m: m["calls"] / m["wakes"] if m["wakes"] else 0),
    ("出错的调用", lambda m: sum(m["failed"].values())),
    *[(f"　{r}", lambda m, r=r: m["failed"][r]) for r in REASONS],
    ("ask 次数", lambda m: m["asks"]),
    ("打扰次数", lambda m: m["interrupts"]["total"]),
    ("　tell（不含 ask）", lambda m: m["interrupts"]["tell"]),
    ("　其中 urgent", lambda m: m["interrupts"]["urgent"]),
    ("　留给他（leave）", lambda m: m["interrupts"]["leave"]),
    ("　其他推送", lambda m: m["interrupts"]["other"]),
    ("回复与 tell 超两句", lambda m: m["overlong"]),
    ("换新次数", lambda m: m["renewals"]),
    ("输入 token", lambda m: m["usage"]["input"]),
    ("缓存读 token", lambda m: m["usage"]["cacheRead"]),
    ("缓存写 token", lambda m: m["usage"]["cacheWrite"]),
    ("输出 token", lambda m: m["usage"]["output"]),
    ("费用 $", lambda m: m["usage"]["cost"]),
    ("每轮用时中位 s", lambda m: statistics.median(m["roundSeconds"]) if m["roundSeconds"] else 0),
]

# 场景单列的那一轮（score.json 的 extra.rounds）：(行名, 键)
SINGLED = [("用时 s", "seconds"), ("费用 $", "cost"), ("输入 token", "input"), ("缓存读 token", "cacheRead"), ("缓存写 token", "cacheWrite"),
           ("输出 token", "output"), ("写的摘要条数", "summaries"), ("新会话的第一轮（1 是）", "renewal")]


def load(run: Path) -> dict:
    """一遍目录里各套的场景：{套: [score…]}"""
    suites = {}
    for path in sorted(run.glob("*.score.json")):
        score = json.loads(path.read_text())
        suites.setdefault(score["suite"], []).append(score)
    return suites


def total(scores: list) -> dict:
    """一遍里一套的合计（短场景是各场景相加；每轮用时放在一起取中位）"""
    out = {"wakes": 0, "calls": 0, "asks": 0, "overlong": 0, "renewals": 0, "roundSeconds": [],
           "failed": dict.fromkeys(REASONS, 0), "interrupts": dict.fromkeys(["tell", "urgent", "leave", "other", "total"], 0),
           "usage": dict.fromkeys(["input", "cacheRead", "cacheWrite", "output", "cost"], 0)}
    for s in scores:
        m = s["metrics"]
        for key in ["wakes", "calls", "asks", "overlong", "renewals"]:
            out[key] += m[key]
        out["roundSeconds"] += m["roundSeconds"]
        for group in ["failed", "interrupts", "usage"]:
            for key, value in m[group].items():
                out[group][key] = out[group].get(key, 0) + value
    return out


def checks(scores: list) -> dict:
    """{(场景, 判定): (类别, 结果)}；结果 True/False，不计的为 None"""
    return {(s["name"], c["label"]): (c["kind"], c["passed"] if c["counted"] else None) for s in scores for c in s["checks"]}


def fmt(x, digits=2) -> str:
    if isinstance(x, float) and not x.is_integer():
        return f"{x:,.{digits}f}" if abs(x) < 100 else f"{x:,.0f}"
    return f"{int(x):,}"


def mean(xs):
    return sum(xs) / len(xs) if xs else 0


def spread(xs):
    return max(xs) - min(xs) if len(xs) > 1 else 0


def mark(result) -> str:
    return "—" if result is None else "✓" if result else "✗"


def suite_report(suite: str, groups: list, names: list, runs: dict) -> list:
    present = [n for g in groups for n in g if suite in runs[n]]
    if not present:
        return []
    groups = [[n for n in g if suite in runs[n]] for g in groups]
    groups = [g for g in groups if g]
    two = len(groups) == 2
    head = present + ["组均值" if not two else "改前均值", *(["改后均值", "差（后−前）"] if two else []), "组内差" if not two else "组内差（前 / 后）"]
    lines = [f"## {suite}", ""]
    errors = [f"{n}：{s['name']}" for n in present for s in runs[n][suite] if s["error"]]
    counts = {n: len(runs[n][suite]) for n in present}
    lines.append("- 场景数：" + "、".join(f"{n} {c}" for n, c in counts.items()) + ("；出错：" + "、".join(errors) if errors else ""))
    lines += ["", "### 判定（通过 / 计入的）", "", "| 类别 | " + " | ".join(head) + " |", "| --- |" + " --- |" * len(head)]
    per = {n: checks(runs[n][suite]) for n in present}

    def row(values: dict, show, digits=2) -> str:
        cells = [show(n) for n in present]
        means = [float(mean([values[n] for n in g])) for g in groups]
        spreads = [float(spread([values[n] for n in g])) for g in groups]
        cells.append(fmt(means[0], digits))
        if two:
            delta = means[1] - means[0]
            cells += [fmt(means[1], digits), ("+" if delta > 0 else "") + fmt(delta, digits), f"{fmt(spreads[0], digits)} / {fmt(spreads[1], digits)}"]
        else:
            cells.append(fmt(spreads[0], digits))
        return " | ".join(cells)

    for kind in KINDS + ["合计"]:
        counted = {n: [r for (k, r) in per[n].values() if r is not None and (kind == "合计" or k == kind)] for n in present}
        passed = {n: sum(counted[n]) for n in present}
        if not any(counted.values()):
            continue
        lines.append(f"| {kind} | " + row(passed, lambda n: f"{passed[n]}/{len(counted[n])}") + " |")

    lines += ["", "### 指标（一遍的合计）", "", "| 指标 | " + " | ".join(head) + " |", "| --- |" + " --- |" * len(head)]
    totals = {n: total(runs[n][suite]) for n in present}
    for name, get in METRICS:
        values = {n: get(totals[n]) for n in present}
        digits = 4 if name.startswith("费用") else 2
        lines.append(f"| {name} | " + row(values, lambda n: fmt(values[n], digits), digits) + " |")

    singled = sorted({r["label"] for n in present for sc in runs[n][suite] for r in sc.get("extra", {}).get("rounds", [])})
    for label in singled:
        picked = {n: next((r for sc in runs[n][suite] for r in sc.get("extra", {}).get("rounds", []) if r["label"] == label), None) for n in present}
        lines += ["", f"### 单列的轮：{label}", "", "| 指标 | " + " | ".join(head) + " |", "| --- |" + " --- |" * len(head)]
        for name, key in SINGLED:
            values = {n: float(picked[n][key]) if picked[n] else 0.0 for n in present}
            digits = 4 if key == "cost" else 2
            lines.append(f"| {name} | " + row(values, lambda n: fmt(values[n], digits) if picked[n] else "—", digits) + " |")

    keys = sorted({k for n in present for k in per[n]})

    def results(group, key):
        return [per[n].get(key, (None, None))[1] for n in group]

    def rate(group, key):
        counted = [r for r in results(group, key) if r is not None]
        return mean(counted) if counted else None

    def trail(key):
        return " / ".join("".join(map(mark, results(g, key))) for g in groups)

    unstable = [k for k in keys if any(len({r for r in results(g, k) if r is not None}) > 1 for g in groups)]
    if two:
        flips = [k for k in keys if None not in (rate(groups[0], k), rate(groups[1], k)) and rate(groups[0], k) != rate(groups[1], k)]
        lines += ["", f"### 翻转（改前、改后通过率不同的判定，{len(flips)} 条）", ""]
        lines += [f"- {'变好' if rate(groups[1], k) > rate(groups[0], k) else '变差'}〔{kind_of(per, k)}〕{k[0]}：{k[1]}（{trail(k)}）" for k in flips] or ["- 没有"]
    lines += ["", f"### 组内不稳（同一设置几遍之间有过有不过，{len(unstable)} 条）", ""]
    lines += [f"- 〔{kind_of(per, k)}〕{k[0]}：{k[1]}（{trail(k)}）" for k in unstable] or ["- 没有"]
    failing = [k for k in keys if k not in unstable and all(r is False for g in groups for r in results(g, k) if r is not None)
               and any(r is not None for g in groups for r in results(g, k))]
    lines += ["", f"### 每遍都没过（{len(failing)} 条）", ""]
    lines += [f"- 〔{kind_of(per, k)}〕{k[0]}：{k[1]}" for k in failing] or ["- 没有"]
    return lines + [""]


def prompt_tokens(suites: dict) -> str:
    """一遍的系统提示估算 token（各场景同一份提示，记忆不同时取各场景里的最小与最大）"""
    tokens = sorted({s["prompt"]["tokens"] for ss in suites.values() for s in ss if "prompt" in s})
    return "—" if not tokens else f"≈{tokens[0]:,}" if len(tokens) == 1 else f"≈{tokens[0]:,}–{tokens[-1]:,}"


def billing(suites: dict):
    """一遍里 Pi 的模型请求：(带计费标识的, 全部)；不是 Pi 为 None"""
    marks = [s["billing"] for ss in suites.values() for s in ss if "billing" in s]
    return (sum(b["marked"] for b in marks), sum(b["requests"] for b in marks)) if marks else None


def kind_of(per: dict, key) -> str:
    return next(v[0] for p in per.values() for k, v in p.items() if k == key)


def main():
    parser = argparse.ArgumentParser(description="Cue 评测成绩单")
    parser.add_argument("runs", type=Path, nargs="+")
    parser.add_argument("--vs", type=Path, nargs="+", default=[])
    args = parser.parse_args()
    groups = [args.runs] + ([args.vs] if args.vs else [])
    names = [r.name for g in groups for r in g]
    if len(set(names)) != len(names):
        raise SystemExit("各遍的目录名要不同（成绩单按目录名列）")
    runs = {r.name: load(r) for g in groups for r in g}
    groups = [[r.name for r in g] for g in groups]
    brains = sorted({s["brain"] for suites in runs.values() for ss in suites.values() for s in ss})
    lines = ["# Cue 评测成绩单", ""]
    lines += [f"- 改前：{'、'.join(groups[0])}", f"- 改后：{'、'.join(groups[1])}"] if len(groups) == 2 else [f"- 各遍：{'、'.join(groups[0])}"]
    lines += [f"- 大脑：{'；'.join(brains)}", "- 系统提示（估算 token，工具说明另算）：" + "、".join(f"{n} {prompt_tokens(runs[n])}" for g in groups for n in g)]
    billed = {n: billing(runs[n]) for g in groups for n in g}
    if any(billed.values()):
        lines.append("- 计费标识（Pi，带 Claude 订阅计费标识的模型请求 / 全部）：" + "、".join(f"{n} {b[0]}/{b[1]}" for n, b in billed.items() if b))
    lines += ["- ✓ 过、✗ 没过、— 这一遍没测到（不计）。组内差是同一设置几遍之间最大减最小：差值小于它的不算改动的效果。", ""]
    for suite in SUITES:
        lines += suite_report(suite, groups, names, runs)
    out = groups[-1][-1]
    path = [r for g in ([args.runs] + ([args.vs] if args.vs else [])) for r in g if r.name == out][0] / "score.md"
    path.write_text("\n".join(lines))
    print(path)


if __name__ == "__main__":
    main()
