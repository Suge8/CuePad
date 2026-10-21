#!/usr/bin/env python3
"""LongMemEval 给 Cue 的长期记忆打分：抽题、判分、出报告。跑法见 docs/verify.md「LongMemEval」。

  lme.py sample [--data DIR] [--holdout]  下载 longmemeval_s_cleaned.json（缺时），按题型分层抽 100 题写成评测读的 sample.jsonl；
                                      --holdout 另抽一份与它不相交、各层题数相同的留出集 holdout.jsonl（改提示词时在 sample 上挑、在留出集上验）
  lme.py judge RUN [RUN…] [--data DIR] 给每个 RUN/<题号>.json 判分（官方分题型判分提示，经 Pi 用 claude-sonnet-5-5），
                                      按给的先后比这几遍，写最后一个 RUN/report.md

判分模型：Pi（anthropic/claude-sonnet-5-5，thinking off），登录从 ~/.pi/agent/auth.json 只读地取、不刷新；
官方用 gpt-4o、temperature 0，Pi 设不了 temperature，判分结果存在每题的 json 里，重跑只判没判过的。
"""
import argparse
import collections
import concurrent.futures
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from datetime import datetime
from pathlib import Path

DATA_URL = "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/longmemeval_s_cleaned.json"
SEED = 42
TOTAL = 100
JUDGE_MODEL = "anthropic/claude-sonnet-5-5"
REPO = Path(__file__).resolve().parents[2]
SUBSCRIPTION = REPO / "apple/CuePadKit/Sources/CuePi/Brain/claude-subscription.ts"
PI = Path.home() / ".local/bin/pi"
PI_AUTH = Path.home() / ".pi/agent/auth.json"
# 一条会话里相邻两句隔这么多秒（数据只给会话的开始时刻）
TURN_GAP = 30


def load(data: Path) -> list:
    path = data / "longmemeval_s_cleaned.json"
    if not path.exists():
        data.mkdir(parents=True, exist_ok=True)
        print(f"下载 {DATA_URL}", file=sys.stderr)
        urllib.request.urlretrieve(DATA_URL, path)
    return json.loads(path.read_text())


def stratum(entry: dict) -> str:
    return entry["question_type"] + ("/拒答" if entry["question_id"].endswith("_abs") else "")


def sample(entries: list, seed: int = SEED, exclude: frozenset = frozenset()) -> list:
    """按题型（拒答题单独一层）分层、按比例抽 TOTAL 题，余数按最大余数法分；层内与层的先后都用固定种子。各层题数按全集算，`exclude` 里的题不抽。"""
    layers = collections.defaultdict(list)
    for entry in entries:
        layers[stratum(entry)].append(entry)
    quota = {name: TOTAL * len(items) / len(entries) for name, items in layers.items()}
    counts = {name: int(q) for name, q in quota.items()}
    for name in sorted(quota, key=lambda n: (-(quota[n] - counts[n]), n))[: TOTAL - sum(counts.values())]:
        counts[name] += 1
    rng = random.Random(seed)
    picked = []
    for name in sorted(layers):
        picked += rng.sample(sorted((e for e in layers[name] if e["question_id"] not in exclude), key=lambda e: e["question_id"]), counts[name])
    return picked


def stamp(text: str) -> float:
    """数据里的时刻（2023/05/20 (Sat) 02:21）按本机时区读成 epoch 秒，同 Cue 信封的日历。"""
    return datetime.strptime(text[:10] + text[-6:], "%Y/%m/%d %H:%M").timestamp()


def timeline(entry: dict) -> list:
    """历史会话按开始时刻排好（同官方 run_generation 的排序），一句一条：会话开始时刻起每句隔 TURN_GAP 秒，且严格递增。"""
    sessions = sorted(zip(entry["haystack_dates"], entry["haystack_sessions"]), key=lambda pair: pair[0])
    log, last = [], float("-inf")
    for date, turns in sessions:
        start = stamp(date)
        for index, turn in enumerate(turns):
            last = max(start + index * TURN_GAP, last + 1)
            log.append(["you" if turn["role"] == "user" else "cue", last, turn["content"]])
    return log


def cmd_sample(args):
    entries = load(args.data)
    picked = sample(entries)
    if args.holdout:
        picked = sample(entries, SEED + 1, frozenset(e["question_id"] for e in picked))
    out = args.data / ("holdout.jsonl" if args.holdout else "sample.jsonl")
    with out.open("w") as f:
        for e in picked:
            f.write(json.dumps({
                "id": e["question_id"], "type": e["question_type"], "question": e["question"], "answer": str(e["answer"]),
                "date": e["question_date"], "asked": stamp(e["question_date"]), "log": timeline(e),
            }, ensure_ascii=False) + "\n")
    print(json.dumps(collections.Counter(stratum(e) for e in picked), ensure_ascii=False))
    print(out)


# 官方判分提示，逐字取自 LongMemEval src/evaluation/evaluate_qa.py 的 get_anscheck_prompt
def anscheck_prompt(task, question, answer, response, abstention=False):
    if not abstention:
        if task in ['single-session-user', 'single-session-assistant', 'multi-session']:
            template = "I will give you a question, a correct answer, and a response from a model. Please answer yes if the response contains the correct answer. Otherwise, answer no. If the response is equivalent to the correct answer or contains all the intermediate steps to get the correct answer, you should also answer yes. If the response only contains a subset of the information required by the answer, answer no. \n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only."
        elif task == 'temporal-reasoning':
            template = "I will give you a question, a correct answer, and a response from a model. Please answer yes if the response contains the correct answer. Otherwise, answer no. If the response is equivalent to the correct answer or contains all the intermediate steps to get the correct answer, you should also answer yes. If the response only contains a subset of the information required by the answer, answer no. In addition, do not penalize off-by-one errors for the number of days. If the question asks for the number of days/weeks/months, etc., and the model makes off-by-one errors (e.g., predicting 19 days when the answer is 18), the model's response is still correct. \n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only."
        elif task == 'knowledge-update':
            template = "I will give you a question, a correct answer, and a response from a model. Please answer yes if the response contains the correct answer. Otherwise, answer no. If the response contains some previous information along with an updated answer, the response should be considered as correct as long as the updated answer is the required answer.\n\nQuestion: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only."
        elif task == 'single-session-preference':
            template = "I will give you a question, a rubric for desired personalized response, and a response from a model. Please answer yes if the response satisfies the desired response. Otherwise, answer no. The model does not need to reflect all the points in the rubric. The response is correct as long as it recalls and utilizes the user's personal information correctly.\n\nQuestion: {}\n\nRubric: {}\n\nModel Response: {}\n\nIs the model response correct? Answer yes or no only."
        else:
            raise NotImplementedError
    else:
        template = "I will give you an unanswerable question, an explanation, and a response from a model. Please answer yes if the model correctly identifies the question as unanswerable. The model could say that the information is incomplete, or some other information is given but the asked information is not.\n\nQuestion: {}\n\nExplanation: {}\n\nModel Response: {}\n\nDoes the model correctly identify the question as unanswerable? Answer yes or no only."
    return template.format(question, answer, response)


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
    references = {e["question_id"]: e for e in load(args.data)}
    files = [f for run in args.runs for f in sorted(run.glob("*.json"))]
    home = Path(tempfile.mkdtemp(prefix="lme-judge-"))
    (home / "agent").mkdir()

    def grade(path: Path):
        result = json.loads(path.read_text())
        if "label" in result:
            return
        ref = references[result["id"]]
        prompt = anscheck_prompt(ref["question_type"], ref["question"], ref["answer"], result["hypothesis"], abstention=result["id"].endswith("_abs"))
        verdict = judge_one(prompt, home)
        result.update(judge=verdict, label="yes" in verdict.lower(), judgeModel=JUDGE_MODEL)
        path.write_text(json.dumps(result, ensure_ascii=False, indent=1))

    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        for future in concurrent.futures.as_completed([pool.submit(grade, f) for f in files]):
            future.result()
    shutil.rmtree(home, ignore_errors=True)
    report(args.runs, references)


SEARCHED = ["查了", "调了 memory 都出错", "没调 memory"]


def searched(result: dict) -> str:
    """问题那一轮查没查：recalls 只收调成的。"""
    if result["recalls"]:
        return SEARCHED[0]
    return SEARCHED[1] if "memory" in result["calls"] else SEARCHED[2]


def report(runs: list, references: dict):
    names = [run.name for run in runs]
    results = {run.name: {r["id"]: r for r in (json.loads(f.read_text()) for f in run.glob("*.json"))} for run in runs}
    ids = sorted(set.intersection(*(set(r) for r in results.values())), key=lambda i: (references[i]["question_type"], i))
    types = sorted({references[i]["question_type"] for i in ids})
    pct = lambda rows: f"{100 * sum(r['label'] for r in rows) / len(rows):.1f}%（{sum(r['label'] for r in rows)}/{len(rows)}）" if rows else "—"
    mean = lambda xs: sum(xs) / len(xs)
    lines = [
        "# LongMemEval（longmemeval_s cleaned）· Cue", "",
        f"- {len(ids)} 道题（按题型分层抽、拒答题单独一层），每个目录是一遍：{'、'.join(names)}。",
        "- 每题一个隔离库，历史会话按原时刻写成 Cue 的对话（用户的话是他的，助手的话是 Cue 的回复），信封上的此刻定在提问时刻；"
        "等刚启用那一轮做完，问题作为他的话交给 Cue，答案是这一轮 Cue 对他说的话。",
        f"- 判分：{JUDGE_MODEL}（经 Pi，thinking off），官方 evaluate_qa.py 的分题型提示，回答里有 yes 算对。",
    ]
    lines += [f"- {n} 的大脑：{'、'.join(sorted({r.get('brain', '—') for r in results[n].values()}))}" for n in names]
    lines += ["", "## 总分与分题型分", "", "| 题型 | " + " | ".join(names) + " |", "| --- |" + " --- |" * len(names)]
    lines.append("| 总分 | " + " | ".join(pct([results[n][i] for i in ids]) for n in names) + " |")
    for t in types:
        lines.append(f"| {t} | " + " | ".join(pct([results[n][i] for i in ids if references[i]["question_type"] == t]) for n in names) + " |")
    abstain = [i for i in ids if i.endswith("_abs")]
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
        ref = references[r["id"]]
        return [
            f"- **{r['id']}**（{searched(r)}）：{ref['question']}（{ref['question_date']}）", f"  - 标准答案：{ref['answer']}",
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
        wrong = [results[last][i] for i in ids if references[i]["question_type"] == t and not results[last][i]["label"]]
        if wrong:
            lines += [f"### {t}", ""] + [line for r in wrong[:3] for line in example(r)]
    lines += ["## 题号", "", ", ".join(sorted(ids)), ""]
    (runs[-1] / "report.md").write_text("\n".join(lines))
    print(runs[-1] / "report.md")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(required=True)
    s = sub.add_parser("sample")
    s.add_argument("--data", type=Path, default=Path("/tmp/lme"))
    s.add_argument("--holdout", action="store_true")
    s.set_defaults(run=cmd_sample)
    j = sub.add_parser("judge")
    j.add_argument("runs", type=Path, nargs="+")
    j.add_argument("--data", type=Path, default=Path("/tmp/lme"))
    j.set_defaults(run=cmd_judge)
    args = parser.parse_args()
    args.run(args)


if __name__ == "__main__":
    main()
