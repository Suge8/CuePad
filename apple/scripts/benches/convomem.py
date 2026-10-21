"""ConvoMem 的读入与官方判分提示。"""
import concurrent.futures
import json
import random
import re
import urllib.parse
import urllib.request
from datetime import datetime, timedelta

from . import SEED, Bench, fetch, sessions_log


class ConvoMem(Bench):
    """ConvoMem（Salesforce/ConvoMem 的 core_benchmark，75,336 题）：按它的六类记忆分层。

    每题照官方 StandardTestCasesGenerator 现拼：同一人物的无关对话随机取够 CONTEXT 段，证据对话按原先后插在随机位置（种子由题号定）。
    数据不给时刻：一段对话一天，最后一段在提问前一天，信封上的此刻定在 ASKED。"""
    name, title, strata = "convomem", "ConvoMem（core_benchmark）", "按六类记忆分层抽"
    base = "https://huggingface.co/datasets/Salesforce/ConvoMem/resolve/main/"
    tree = "https://huggingface.co/api/datasets/Salesforce/ConvoMem/tree/main/"
    setup = "证据对话混进同一人物的无关对话共 50 段，一天一段写成他与 Cue 的对话（User 是他，Assistant 是 Cue），信封上的此刻定在最后一段的次日"
    judging = "官方 AnsweringEvaluation.scala 的分类判分提示，回 RIGHT（且没有 WRONG）算对"
    # 每题的对话段数（官方 2–300 段里取一档）：50 段约 2500 句、36 万字，与 longmemeval_s 一题的量相当
    CONTEXT = 50
    ASKED = datetime(2025, 6, 2, 9, 0)
    types = {
        "user_evidence": "user-facts", "assistant_facts_evidence": "assistant-facts", "changing_evidence": "changing-facts",
        "abstention_evidence": "abstention", "preference_evidence": "preferences", "implicit_connection_evidence": "implicit-connections",
    }

    def files(self, folder: str) -> list:
        url, paths = f"{self.tree}core_benchmark/{folder}?recursive=true", []
        while url:
            with urllib.request.urlopen(url) as response:
                paths += [e["path"] for e in json.load(response) if e["type"] == "file"]
                link = re.search(r'<([^>]+)>; rel="next"', response.headers.get("Link") or "")
            url = link and link.group(1)
        with concurrent.futures.ThreadPoolExecutor(16) as pool:
            list(pool.map(lambda p: fetch(self.base + urllib.parse.quote(p), self.data / p), paths))
        return sorted(self.data / p for p in paths)

    def entries(self):
        self.files("filler_conversations")
        entries = []
        for path in self.files("evidence_questions"):
            category, count = path.parts[-3], int(path.parts[-2].split("_")[0])
            for index, item in enumerate(json.loads(path.read_text())["evidence_items"]):
                entries.append(dict(item, id=f"{self.types[category]}-{count}-{path.stem[:8]}-{index}", category=category, count=count))
        return entries

    def stratum(self, entry):
        return self.types[entry["category"]]

    def line(self, e):
        rng = random.Random(f"{SEED}-{e['id']}")
        filler = next((self.data / "core_benchmark/filler_conversations").glob(f"{e['personId']}_*.json"))
        fillers = [c for item in json.loads(filler.read_text())["evidence_items"] for c in item["conversations"]]
        evidence = e["conversations"]
        picked = rng.sample(fillers, self.CONTEXT - len(evidence))
        slots = sorted(rng.sample(range(self.CONTEXT), len(evidence)))
        for slot, conversation in zip(slots, evidence):
            picked.insert(slot, conversation)
        sessions = [
            ((self.ASKED - timedelta(days=self.CONTEXT - day, hours=-1)).timestamp(),
             [("you" if m["speaker"].lower() == "user" else "cue", m["text"]) for m in conversation["messages"]])
            for day, conversation in enumerate(picked)
        ]
        return {
            "id": e["id"], "type": self.types[e["category"]], "question": e["question"], "answer": e["answer"],
            "abstain": e["category"] == "abstention_evidence", "evidence": [m["text"] for m in e["message_evidences"]],
            "date": self.ASKED.strftime("%Y/%m/%d (%a) %H:%M"), "asked": self.ASKED.timestamp(), "log": sessions_log(sessions),
        }

    # 官方判分提示，逐字取自 ConvoMem src/main/scala/com/salesforce/crmmembench/questions/evidence/generation/AnsweringEvaluation.scala；
    # 各类用哪个照各自的 EvidenceGenerator.getAnsweringEvaluation（他的事实：UserFacts；拒答：Abstention；偏好与隐含关联：RubricBased；其余 Default）
    DEFAULT = """I will provide you with a **Question**, a **Correct Answer**, and a **Model's Response**. Your sole task is to determine if the Model's Response is **sufficiently correct and complete** to answer the Question, when compared against the Correct Answer.

**Crucial Guidelines for your judgment:**

1.  **Core Information is Key**: The Model's Response must contain all the **essential factual information** that directly answers the Question.
2.  **Equivalence Counts**: Phrasing doesn't need to be identical. If the Model's Response conveys the exact same core meaning and details as the Correct Answer, even if paraphrased or structured differently, consider it correct.
3.  **Superfluous (but Accurate) Information**: If the Model's Response includes additional details that were *not explicitly asked for* by the Question, but these details are **accurate and do not contradict** the Correct Answer, you should **still count it as correct** if the core question is fully answered.
4.  **Partial Answers are Incorrect**: If the Model's Response is missing any essential information directly requested by the Question (even if the Correct Answer provides more detail), it is incorrect.
5.  **Focus on the Question**: Your primary focus should be whether the Model's Response adequately addresses the Question using information that aligns with the Correct Answer. Do not penalize the model for not reiterating every single word or incidental detail from the Correct Answer if it wasn't requested.

**Answer only "RIGHT" or "WRONG". Do not provide any additional text, explanations, or reasoning.**

Question: {question}
Correct Answer: {answer}
Model Response: {response}

Answer (RIGHT/WRONG):"""

    RUBRIC = """You are a judge evaluating if a model's response meets the criteria in a rubric.

Question asked: {question}

Evaluation rubric: {answer}

Model's response: {response}

Guidelines:
- The model's response must fully satisfy ALL criteria in the rubric
- Partial fulfillment of criteria should result in INCORRECT
- The response must demonstrate clear understanding of the context
- Missing any important aspect mentioned in the rubric means INCORRECT

Evaluate whether the model's response satisfies the rubric criteria.

If the response satisfies the criteria: RIGHT
If the response does not satisfy the criteria: WRONG

Respond with only RIGHT or WRONG."""

    USER_FACT = """You are evaluating whether a model's response correctly answers a question using information from an evidence message.

**Your Task:**
Determine if the Model's Response is RIGHT or WRONG based on the following criteria.

**Question Asked:** 
{question}

**Evidence Message Available to the Model:**
{evidence}

**Correct Answer (what the response should convey):**
{answer}

**Model's Response to Evaluate:**
{response}

**Evaluation Criteria:**

When the response is RIGHT:
- The core answer matches the Correct Answer (exact phrasing not required)
- The response demonstrates understanding of the information from the evidence message
- The response correctly addresses the question asked
- If the model includes accurate additional details not in the Correct Answer, that's still RIGHT

When the response is WRONG:
- The core answer contradicts or significantly differs from the Correct Answer
- Critical information from the evidence message is missing or misunderstood
- The response shows confusion about the facts
- The response fails to answer the question asked

**Important Notes:**
- The model doesn't need to quote the evidence message verbatim
- Paraphrasing or summarization is expected and acceptable
- Focus on whether the essential information has been correctly conveyed

**Answer only "RIGHT" or "WRONG". Do not provide any additional text, explanations, or reasoning.**

Answer (RIGHT/WRONG):"""

    USER_FACTS = """You are evaluating whether a model's response correctly answers a question using information from multiple evidence messages.

**Your Task:**
Determine if the Model's Response is RIGHT or WRONG based on the following criteria.

**Question Asked:** 
{question}

**Evidence Messages Available to the Model:**
{evidence}

**Correct Answer (what the response should convey):**
{answer}

**Model's Response to Evaluate:**
{response}

**Evaluation Criteria:**

When the response is RIGHT:
- The core answer matches the Correct Answer (exact phrasing not required)
- Information from most evidence messages is reasonably reflected in the response
- The response shows understanding and synthesis of the multiple pieces of information
- Minor omissions are acceptable if the main answer is correct

When the response is WRONG:
- The core answer contradicts or significantly differs from the Correct Answer
- Critical information from multiple evidence messages is completely missing
- The response shows misunderstanding or confusion about the facts
- The response fails to answer the question asked

**Important Notes:**
- The model doesn't need to explicitly cite each evidence message
- Focus on whether the essential information has been incorporated, not perfect completeness
- Some paraphrasing or summarization is expected and acceptable
- If the model includes accurate additional details not in the Correct Answer, that's still RIGHT

**Answer only "RIGHT" or "WRONG". Do not provide any additional text, explanations, or reasoning.**

Answer (RIGHT/WRONG):"""

    ABSTENTION = """You are evaluating an ABSTENTION test where the model should recognize it lacks sufficient information to answer the question.

**This is an abstention test - the model SHOULD refuse to answer or say it doesn't know.**

**Critical Guidelines for Abstention Evaluation:**

1. **Abstention is Success**: If the model refuses to answer, says it doesn't know, or indicates insufficient information, this is CORRECT behavior for abstention tests.

2. **Various Forms of Abstention are Acceptable**:
   - "I don't know" / "I'm not sure" / "I cannot determine"
   - "There is no information about..." / "This wasn't mentioned..."
   - "I don't have enough information to answer..."
   - "Based on the conversation, I cannot tell..."
   - "This information wasn't provided..."
   - Asking for clarification or more information

3. **Hallucination is Failure**: If the model provides a specific answer that wasn't in the evidence, this is WRONG, even if it seems plausible.

4. **Partial Information Recognition**: If the model correctly identifies what information IS available while noting what is missing, this is RIGHT.

5. **Key Principle**: The goal is to test whether the model can recognize the limits of its knowledge. Any response that demonstrates this recognition should be marked as RIGHT.

**Answer only "RIGHT" or "WRONG". Do not provide any additional text, explanations, or reasoning.**

Question: {question}
Expected behavior: The model should indicate it cannot answer due to insufficient information
Model Response: {response}

Does the model appropriately abstain from answering or acknowledge insufficient information?

Answer (RIGHT/WRONG):"""

    def prompt(self, r):
        evidence = r["evidence"]
        if r["type"] == "user-facts":
            template = self.USER_FACT if len(evidence) == 1 else self.USER_FACTS
            shown = evidence[0] if len(evidence) == 1 else "\n".join(f"Evidence Message {i + 1}: {text}" for i, text in enumerate(evidence))
        else:
            template = {"abstention": self.ABSTENTION, "preferences": self.RUBRIC, "implicit-connections": self.RUBRIC}.get(r["type"], self.DEFAULT)
            shown = ""
        return template.format(question=r["question"], answer=r["answer"], response=r["hypothesis"], evidence=shown)

    def passed(self, result, verdict):
        # 官方：小写后含 right 不含 wrong 算对，两个都含算错
        verdict = verdict.lower()
        return "right" in verdict and "wrong" not in verdict
