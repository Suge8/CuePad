#!/usr/bin/env python3
"""记忆基准（LongMemEval、LoCoMo、ConvoMem）给 Cue 的长期记忆打分：抽题、判分、出报告。跑法见 docs/verify.md「记忆基准」。

  bench.py sample BENCH [--data DIR] [--holdout]  下载 BENCH（lme / locomo / convomem）的官方数据到 DIR（缺省 /tmp/bench/BENCH，缺时才下），
                                      按层抽 100 题（种子 42）写成评测读的 DIR/sample.jsonl；--holdout 另抽一份与它不相交、各层题数相同的 holdout.jsonl
  bench.py judge RUN [RUN…]           给每个 RUN/<题号>.json 判分（各家的判分提示，经 Pi 用 claude-sonnet-5-5），按给的先后比这几遍，写最后一个 RUN/report.md

三家的差别只在各自的读入（benches/ 里各家一个 `Bench` 子类：读官方数据、分层、把历史排成一句一条、判分提示与怎么读判词），
抽题、评测读的题目行、判分、报告只有一份。题目行：bench、id、type、question、answer、abstain（该拒答）、evidence（判分要看的证据原话）、
date（提问时刻的字面）、asked（epoch 秒）、log（[作者 you/cue, epoch 秒, 正文]，按时刻排好）；评测把除 log 外的字段原样抄进每题的结果，判分只读结果。

判分模型：Pi（anthropic/claude-sonnet-5-5，thinking off），登录从 ~/.pi/agent/auth.json 只读地取、不刷新；
官方用 gpt-4o / gpt-4o-mini / Gemini，Pi 设不了 temperature，判分结果存在每题的 json 里，重跑只判没判过的。
"""
import argparse
import collections
import concurrent.futures
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

from benches import SEED, Bench
from benches.convomem import ConvoMem
from benches.lme import LongMemEval
from benches.locomo import LoCoMo

JUDGE_MODEL = "anthropic/claude-sonnet-5-5"
REPO = Path(__file__).resolve().parents[2]
SUBSCRIPTION = REPO / "apple/CuePadKit/Sources/CuePi/Brain/claude-subscription.ts"
PI = Path.home() / ".local/bin/pi"
PI_AUTH = Path.home() / ".pi/agent/auth.json"


BENCHES = {bench.name: bench for bench in (LongMemEval, LoCoMo, ConvoMem)}


def cmd_sample(args):
    bench = BENCHES[args.bench](args.data or Path("/tmp/bench") / args.bench)
    entries = bench.entries()
    picked = bench.sample(entries)
    if args.holdout:
        picked = bench.sample(entries, SEED + 1, frozenset(bench.ident(e) for e in picked))
    out = bench.data / ("holdout.jsonl" if args.holdout else "sample.jsonl")
    with out.open("w") as f:
        for e in picked:
            f.write(json.dumps(dict(bench=bench.name, **bench.line(e)), ensure_ascii=False) + "\n")
    print(json.dumps(collections.Counter(bench.stratum(e) for e in picked), ensure_ascii=False))
    print(out)


def judge_one(prompt: str, home: Path) -> str:
    token = subprocess.run(
        ["/usr/bin/plutil", "-extract", "anthropic.access", "raw", "-o", "-", str(PI_AUTH)], check=True, capture_output=True, text=True).stdout.strip()
    env = {k: v for k, v in os.environ.items() if not k.startswith(("ANTHROPIC_", "XDG_"))}
    env.update(ANTHROPIC_OAUTH_TOKEN=token, PI_CODING_AGENT_DIR=str(home / "agent"), HOME=str(home), CUEPAD_CLAUDE=shutil.which("claude") or "claude")
    command = [
        str(PI), "-p", "--no-session", "--offline", "-ne", "-nt", "-ns", "-nc", "-np", "--no-themes", "-e", str(SUBSCRIPTION),
        # 空的系统提示过不了订阅计费标识那一步（扩展把标识插在系统提示的块前面）
        "--system-prompt", "You are a helpful assistant.", "--model", JUDGE_MODEL, "--thinking", "off", prompt,
    ]
    for attempt in range(4):
        done = subprocess.run(command, env=env, capture_output=True, text=True, timeout=300)
        if done.returncode == 0 and done.stdout.strip():
            return done.stdout.strip()
        time.sleep(5 * (attempt + 1))
    raise RuntimeError(f"判分失败：{done.stderr.strip()[-300:]}")


def cmd_judge(args):
    expires = json.loads(PI_AUTH.read_text())["anthropic"]["expires"] / 1000
    if expires < time.time():
        sys.exit("Pi 的 Anthropic 令牌已过期：等用户自己的 Pi 续上，判分不替它刷新")
    files = [f for run in args.runs for f in sorted(run.glob("*.json"))]
    benches = {json.loads(f.read_text())["bench"] for f in files}
    if len(benches) != 1:
        sys.exit(f"一次只判一家基准的结果：{'、'.join(sorted(benches)) or '没有结果'}")
    bench = BENCHES[benches.pop()](Path())
    home = Path(tempfile.mkdtemp(prefix="bench-judge-"))
    (home / "agent").mkdir()

    def grade(path: Path):
        result = json.loads(path.read_text())
        if "label" in result:
            return
        verdict = judge_one(bench.prompt(result), home)
        result.update(judge=verdict, label=bench.passed(result, verdict), judgeModel=JUDGE_MODEL)
        path.write_text(json.dumps(result, ensure_ascii=False, indent=1))

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for future in concurrent.futures.as_completed([pool.submit(grade, f) for f in files]):
            future.result()
    shutil.rmtree(home, ignore_errors=True)
    report(bench, args.runs)


SEARCHED = ["查了", "调了 memory 都出错", "没调 memory"]


def searched(result: dict) -> str:
    """问题那一轮查没查：recalls 只收调成的。"""
    if result["recalls"]:
        return SEARCHED[0]
    return SEARCHED[1] if "memory" in result["calls"] else SEARCHED[2]


def report(bench: Bench, runs: list):
    names = [run.name for run in runs]
    results = {run.name: {r["id"]: r for r in (json.loads(f.read_text()) for f in run.glob("*.json"))} for run in runs}
    ref = results[names[-1]]
    ids = sorted(set.intersection(*(set(r) for r in results.values())), key=lambda i: (ref[i]["type"], i))
    types = sorted({ref[i]["type"] for i in ids})
    pct = lambda rows: f"{100 * sum(r['label'] for r in rows) / len(rows):.1f}%（{sum(r['label'] for r in rows)}/{len(rows)}）" if rows else "—"
    mean = lambda xs: sum(xs) / len(xs)
    lines = [
        f"# {bench.title} · Cue", "",
        f"- {len(ids)} 道题（{bench.strata}），每个目录是一遍：{'、'.join(names)}。",
        f"- 每题一个隔离库，{bench.setup}；等刚启用那一轮做完，问题作为他的话交给 Cue，答案是这一轮 Cue 对他说的话。",
        f"- 判分：{JUDGE_MODEL}（经 Pi，thinking off），{bench.judging}。",
    ]
    lines += [f"- {n} 的大脑：{'、'.join(sorted({r.get('brain', '—') for r in results[n].values()}))}" for n in names]
    lines += ["", "## 总分与分题型分", "", "| 题型 | " + " | ".join(names) + " |", "| --- |" + " --- |" * len(names)]
    lines.append("| 总分 | " + " | ".join(pct([results[n][i] for i in ids]) for n in names) + " |")
    for t in types:
        lines.append(f"| {t} | " + " | ".join(pct([results[n][i] for i in ids if ref[i]["type"] == t]) for n in names) + " |")
    abstain = [i for i in ids if ref[i]["abstain"]]
    lines.append("| 其中拒答题 | " + " | ".join(pct([results[n][i] for i in abstain]) for n in names) + " |")

    lines += ["", "## 开销与用时（问题那一轮；合计含刚启用那一轮）", "", "| 一遍 | 用时中位 | 用时均值 | 费用均值（问题轮） | 费用均值（合计） | 输入+缓存读 均值 | recall 次数均值 |", "| --- | --- | --- | --- | --- | --- | --- |"]
    for n in names:
        rows = [results[n][i] for i in ids]
        el = sorted(r["elapsed"] for r in rows)
        lines.append(
            f"| {n} | {el[len(el) // 2]:.1f}s | {mean(el):.1f}s | ${mean([r['usage']['cost'] for r in rows]):.4f} | ${mean([r['total']['cost'] for r in rows]):.4f} | "
            f"{mean([r['usage']['input'] + r['usage']['cacheRead'] for r in rows]):.0f} | {mean([len(r['recalls']) for r in rows]):.2f} |")

    lines += ["", "## 查没查（问题那一轮，每格是这一类的正确率）", "", "| 一遍 | " + " | ".join(SEARCHED) + " |", "| --- |" + " --- |" * len(SEARCHED)]
    for n in names:
        rows = [results[n][i] for i in ids]
        lines.append(f"| {n} | " + " | ".join(pct([r for r in rows if searched(r) == kind]) for kind in SEARCHED) + " |")

    def example(r):
        return [
            f"- **{r['id']}**（{searched(r)}）：{r['question']}（{r['date']}）", f"  - 标准答案：{r['answer']}",
            f"  - recall：{'；'.join(r['recalls']) or '—'}", "  - Cue：" + " ".join(r["hypothesis"].split())[:300], "",
        ]

    if len(names) >= 2:
        a, b = results[names[0]], results[names[-1]]
        gained = [i for i in ids if b[i]["label"] and not a[i]["label"]]
        lost = [i for i in ids if a[i]["label"] and not b[i]["label"]]
        neither = [i for i in ids if not a[i]["label"] and not b[i]["label"]]
        kinds = collections.Counter(f"{searched(a[i])}/{searched(b[i])}" for i in neither)
        lines += [
            "", f"## {names[0]} → {names[-1]}", "",
            f"- 两遍都对 {len(ids) - len(gained) - len(lost) - len(neither)} 题，两遍都错 {len(neither)} 题（查没查：" + "、".join(f"{k} {c}" for k, c in kinds.most_common()) + "）。",
            f"- 变对 {len(gained)} 题：{', '.join(gained) or '—'}", f"- 变错 {len(lost)} 题：{', '.join(lost) or '—'}",
        ]
    last = names[-1]
    lines += ["", f"## 失败（{last}，每题型至多三个）", ""]
    for t in types:
        wrong = [ref[i] for i in ids if ref[i]["type"] == t and not ref[i]["label"]]
        if wrong:
            lines += [f"### {t}", ""] + [line for r in wrong[:3] for line in example(r)]
    lines += ["## 题号", "", ", ".join(sorted(ids)), ""]
    (runs[-1] / "report.md").write_text("\n".join(lines))
    print(runs[-1] / "report.md")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(required=True)
    s = sub.add_parser("sample")
    s.add_argument("bench", choices=BENCHES)
    s.add_argument("--data", type=Path)
    s.add_argument("--holdout", action="store_true")
    s.set_defaults(run=cmd_sample)
    j = sub.add_parser("judge")
    j.add_argument("runs", type=Path, nargs="+")
    j.set_defaults(run=cmd_judge)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
