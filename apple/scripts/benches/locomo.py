"""LoCoMo 的读入与判分提示。"""
import json
import re
from datetime import datetime, timedelta

from . import Bench, fetch, sessions_log, stamp


from .lme import LongMemEval


class LoCoMo(Bench):
    """LoCoMo（snap-research/LoCoMo 的 locomo10.json，10 段对话、1986 题）：按官方的五类分层，对抗题（第 5 类，问的是没发生在这个人身上的事，
    该答"没提过"）就是它的拒答题，照比例抽进来。

    LoCoMo 是两个人之间的聊天，Cue 的对话里只有他与 Cue：两人的话都记成他的（他把聊天原样记下），每句照官方拼上下文的写法
    `<名字> said, "<原话>"`（带图的再接 ` and shared <图注>.`），问题里点名的是谁一看就知道；任何一方写成 Cue 的回复，Cue 会以为那些话是自己说的。
    数据不给提问时刻，定在最后一段对话开始后一天。"""
    name, title, strata = "locomo", "LoCoMo（locomo10）", "按官方五类分层抽，对抗题即拒答题"
    url = "https://raw.githubusercontent.com/snap-research/LoCoMo/main/data/locomo10.json"
    setup = "两人的聊天按原时刻写成他的话（每句 `<名字> said, \"…\"`），信封上的此刻定在最后一段对话开始后一天"
    judging = "第 1–4 类用 Mem0 论文的 LLM 判分提示（LoCoMo 官方只有词重叠 F1，没有判分提示），回 CORRECT 算对；对抗题用 LongMemEval 官方的拒答判分提示"
    # 官方 task_eval/evaluation.py 的类别号：1 多跳、2 时间、3 开放域（常识推断）、4 单跳、5 对抗
    types = {1: "multi-hop", 2: "temporal", 3: "open-domain", 4: "single-hop", 5: "adversarial"}
    form = "%I:%M %p on %d %B, %Y"
    # 对抗题的标准答案：官方让模型在它与对抗答案里二选一，选它算对
    not_mentioned = "Not mentioned in the conversation"

    def entries(self):
        path = self.data / "locomo10.json"
        fetch(self.url, path)
        return [
            dict(qa, id=f"{sample['sample_id']}-q{index}", conversation=sample["conversation"])
            for sample in json.loads(path.read_text()) for index, qa in enumerate(sample["qa"])
        ]

    def stratum(self, entry):
        return self.types[entry["category"]]

    def line(self, e):
        c = e["conversation"]
        numbers = [int(k.split("_")[1]) for k in c if re.fullmatch(r"session_\d+", k)]
        said = lambda turn: f'{turn["speaker"]} said, "{turn["text"]}"' + (f' and shared {turn["blip_caption"]}.' if "blip_caption" in turn else "")
        sessions = [(stamp(c[f"session_{n}_date_time"], self.form), [("you", said(turn)) for turn in c[f"session_{n}"]]) for n in numbers]
        asked = datetime.fromtimestamp(max(start for start, _ in sessions)) + timedelta(days=1)
        abstain = e["category"] == 5
        return {
            "id": e["id"], "type": self.types[e["category"]], "question": e["question"],
            "answer": self.not_mentioned if abstain else str(e["answer"]), "abstain": abstain, "evidence": [],
            "date": asked.strftime(self.form), "asked": asked.timestamp(), "log": sessions_log(sessions),
        }

    # Mem0 论文的 LoCoMo 判分提示，逐字取自 mem0ai/mem0 evaluation/metrics/llm_judge.py 的 ACCURACY_PROMPT（aae5989 版）
    ACCURACY_PROMPT = """
Your task is to label an answer to a question as ’CORRECT’ or ’WRONG’. You will be given the following data:
    (1) a question (posed by one user to another user), 
    (2) a ’gold’ (ground truth) answer, 
    (3) a generated answer
which you will score as CORRECT/WRONG.

The point of the question is to ask about something one user should know about the other user based on their prior conversations.
The gold answer will usually be a concise and short answer that includes the referenced topic, for example:
Question: Do you remember what I got the last time I went to Hawaii?
Gold answer: A shell necklace
The generated answer might be much longer, but you should be generous with your grading - as long as it touches on the same topic as the gold answer, it should be counted as CORRECT. 

For time related questions, the gold answer will be a specific date, month, year, etc. The generated answer might be much longer or use relative time references (like "last Tuesday" or "next month"), but you should be generous with your grading - as long as it refers to the same date or time period as the gold answer, it should be counted as CORRECT. Even if the format differs (e.g., "May 7th" vs "7 May"), consider it CORRECT if it's the same date.

Now it's time for the real question:
Question: {question}
Gold answer: {gold_answer}
Generated answer: {generated_answer}

First, provide a short (one sentence) explanation of your reasoning, then finish with CORRECT or WRONG. 
Do NOT include both CORRECT and WRONG in your response, or it will break the evaluation script.

Just return the label CORRECT or WRONG in a json format with the key as "label".
"""

    def prompt(self, r):
        if r["abstain"]:
            return LongMemEval.anscheck_prompt("", r["question"], r["answer"], r["hypothesis"], abstention=True)
        return self.ACCURACY_PROMPT.format(question=r["question"], gold_answer=r["answer"], generated_answer=r["hypothesis"])

    def passed(self, result, verdict):
        if result["abstain"]:
            return "yes" in verdict.lower()
        # Mem0 读 json 里的 label；判词没写成 json 时取最后一个标签
        labels = re.findall(r'"label"\s*:\s*"(CORRECT|WRONG)"', verdict) or re.findall(r"\b(CORRECT|WRONG)\b", verdict)
        return labels[-1:] == ["CORRECT"]
