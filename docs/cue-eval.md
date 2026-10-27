# Cue 评测

改 Cue 的系统提示、工具说明、信封或记忆前后各跑一遍，比同一套场景里真模型的做法。大脑缺省是这台 Mac 上 Claude Code 自己的登录，换 Pi、Codex 与换模型、强度见 `EvalBrain` 头注释；经 xcodebuild 传的环境变量要加 `TEST_RUNNER_` 前缀。

## 三套场景

```bash
# 短场景
TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=pi TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/new-short-1 CUEPAD_TEST_TIME_LIMIT=900 \
  apple/scripts/xc.sh test mac -parallel-testing-enabled YES -only-testing:CuePadTests/CueEvalTests
# 长程（十分钟左右）：_RUNS=2 同时跑两遍、第 n 遍写到"输出目录-n"
TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=pi TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/new-long TEST_RUNNER_CUEPAD_CUE_EVAL_RUNS=2 CUEPAD_TEST_TIME_LIMIT=3600 \
  apple/scripts/xc.sh test mac -parallel-testing-enabled YES -only-testing:CuePadTests/CueEvalLongTests
# 多日记忆（十分钟左右）：一次一遍
TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=pi TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/new-days-1 CUEPAD_TEST_TIME_LIMIT=1700 \
  apple/scripts/xc.sh test mac -only-testing:CuePadTests/CueEvalDaysTests
```

- 长程、多日考什么、怎么换新，在 `CueEvalLongTests`、`CueEvalDaysTests` 的头注释。只改了一两类行为时，短场景可用 `-only-testing:'CuePadTests/CueEvalTests/<函数名>()'` 只跑受影响的几个，结论照样看两遍以上。
- 输出目录每个场景一个 .md（信封、工具调用、Cue 写的消息、判定与每一轮的开销）与一份 `<场景>.score.json`，这一遍的系统提示在 `system-prompt.md`。有场景没过时非零退出，输出照样写完。每个场景的库留在 `<场景>.library`，用 `CUEPAD_SHOT_LIBRARY=<它> xc.sh shot mac out.png -- -CuePadScene cue` 看。
- 开销是大脑自报的 token 与费用；后台做梦的大脑输出另存 `usage/dream`，逐轮开销与换新只数 Cue 的。缓存跨场景命中一小时，先后跑的缓存读写会不同。

## 问与打扰的专门场景

| 场景 | 设定 | 该怎么做 |
| --- | --- | --- |
| v | 会话把删数据说成清理的一步 | tell 带 ask=delete |
| w | 他亲口放行过推送 | 直接答推送，不问 |
| x | 一次性的定时到点（提醒他的约定） | 一条 tell 带 urgent |
| x2 | 他要每周定时做一件事 | 建任务不开工，remind 带 repeat 与 task |
| x3 | 挂在任务上的每周定时到点 | 开工那件任务，不 done、不打扰 |
| k、y | 会话交回界面方案、停下问配色 | ask=taste 带方案图（每个方案一张、推荐的在前），不留给他；他点可以后转给会话 |
| o、o2 | 他自己那一轮（CuePad 已留给他回）：会话答了他问的、碰上推送 | 留着待回复，不收回、不 say、不 tell |
| z | 他那一轮会话只应了一声 | task take 收回，不 tell |
| o3 | 调研交回，正文写他看完再定 | 一句 tell 说结论与要他定的，再留给他回，先不 done |

他发起的一轮与会话的常规停下另判"没 tell"。

## 成绩单

改系统提示、工具、记忆前后，短场景、长程、多日各跑两遍（Pi + sonnet · medium），每遍一个目录，再比（用法与输出在 `score.py` 头注释）：

```bash
python3 apple/scripts/score.py /tmp/cue-eval/base-short-{1,2} /tmp/cue-eval/base-long-{1,2} /tmp/cue-eval/base-days-{1,2} \
  --vs /tmp/cue-eval/new-short-{1,2} /tmp/cue-eval/new-long-{1,2} /tmp/cue-eval/new-days-{1,2}
```

- 判定的类别见 `CheckKind`，出错调用的分法见 `CallFailure`；前提这一遍没出现的判定记"不计"，不进通过数。
- 打扰 = tell（不含 ask、撤回、放回）+ task leave（他收到"待回复"）+ 其他推送（管理器写的 urgent，如出错）；回他的话不算。
- 回复与 tell 超两句按系统提示的上限数；他问进展的那一轮上限是两句与件数（非空的行）里大的那个。
- 怎么看：先看组内差（同一设置几遍之间最大减最小），差值没超过它的不算改动的效果；再看翻转、组内不稳与每遍都没过的。改了判定的措辞，它在成绩单里就是另一条（按措辞认身份），改前改后各列一次。
- 多日另记合并（按摘要认）：在哪一轮、哪一步、几条摘要、之后视图几行，见 .md 的「多日」；单列的轮另出一表。

## 记忆基准

改 Cue 的提示词或 recall 前后各跑一遍，用 LongMemEval（`lme`）、LoCoMo（`locomo`）、ConvoMem（`convomem`）给长期记忆打分（抽题、判分在 `bench.py` 头注释，每题怎么跑在 `CueEvalBenchTests` 头注释）：

```bash
B=locomo
python3 apple/scripts/bench.py sample $B
TEST_RUNNER_CUEPAD_BENCH_DATA=/tmp/bench/$B/sample.jsonl TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=pi TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/$B-after \
  CUEPAD_TEST_TIME_LIMIT=7200 apple/scripts/xc.sh test mac -only-testing:CuePadTests/CueEvalBenchTests
python3 apple/scripts/bench.py judge /tmp/cue-eval/$B-before /tmp/cue-eval/$B-after
```

- 改提示词时在 sample 上挑改法，在留出集（`sample $B --holdout`）上验。
- `TEST_RUNNER_CUEPAD_BENCH_ONLY=<题号,…>` 只跑几题，`_LANES` 同时跑几题（缺省 8，一遍约四五分钟）。重判一题先删掉它 .json 里的 `label`。大脑那边一遍之间差几题，结论看两遍以上。
