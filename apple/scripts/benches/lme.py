"""LongMemEval 的读入与官方判分提示。"""
import json

from . import Bench, fetch, sessions_log, stamp


class LongMemEval(Bench):
    """LongMemEval（longmemeval_s cleaned，500 题）：题型分层，拒答题（题号以 _abs 结尾）单独一层。"""
    name, title, strata = "lme", "LongMemEval（longmemeval_s cleaned）", "按题型分层抽、拒答题单独一层"
    url = "https://huggingface.co/datasets/xiaowu0162/longmemeval-cleaned/resolve/main/longmemeval_s_cleaned.json"
    setup = "历史会话按原时刻写成 Cue 的对话（用户的话是他的，助手的话是 Cue 的回复），信封上的此刻定在提问时刻"
    judging = "官方 evaluate_qa.py 的分题型提示，回答里有 yes 算对"
    form = "%Y/%m/%d %H:%M"

    def entries(self):
        path = self.data / "longmemeval_s_cleaned.json"
        fetch(self.url, path)
        return json.loads(path.read_text())

    def ident(self, entry):
        return entry["question_id"]

    def stratum(self, entry):
        return entry["question_type"] + ("/拒答" if entry["question_id"].endswith("_abs") else "")

    def stamp(self, text):
        return stamp(text[:10] + text[-6:], self.form)  # 2023/05/20 (Sat) 02:21

    def line(self, e):
        sessions = [
            (self.stamp(date), [("you" if turn["role"] == "user" else "cue", turn["content"]) for turn in turns])
            for date, turns in zip(e["haystack_dates"], e["haystack_sessions"])
        ]
        return {
            "id": e["question_id"], "type": e["question_type"], "question": e["question"], "answer": str(e["answer"]),
            "abstain": e["question_id"].endswith("_abs"), "evidence": [], "date": e["question_date"], "asked": self.stamp(e["question_date"]),
            "log": sessions_log(sessions),
        }

    # 官方判分提示，逐字取自 LongMemEval src/evaluation/evaluate_qa.py 的 get_anscheck_prompt
    @staticmethod
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

    def prompt(self, r):
        return self.anscheck_prompt(r["type"], r["question"], r["answer"], r["hypothesis"], abstention=r["abstain"])

    def passed(self, result, verdict):
        return "yes" in verdict.lower()
