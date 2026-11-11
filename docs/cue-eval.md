# Cue 评测

改 Cue 的系统提示、工具说明、信封或记忆前后各跑一遍，比同一套场景里真模型的做法。大脑缺省是这台 Mac 上 Claude Code 自己的登录，换 Pi、Codex 与换模型、强度见 `EvalBrain` 头注释（Pi 没有 Anthropic 登录时，`_MODEL` 给 ~/.pi/agent/models.json 里的提供方，如 `magpie/claude/claude-sonnet-5-5`）；经 xcodebuild 传的环境变量要加 `TEST_RUNNER_` 前缀。

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

## 换大脑

Pi 额度用完、自动换到这台 Mac 上另一家真的 Agent 之后，那家能不能起来接着答（`CueEvalFailoverTests`）。换上的那家用 `_RUNTIME` 选，不能是 Pi：

```bash
TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=codex TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/failover CUEPAD_TEST_TIME_LIMIT=900 \
  apple/scripts/xc.sh test mac -only-testing:CuePadTests/CueEvalFailoverTests
```

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

## 做事的标准的专门场景

| 场景 | 设定 | 该怎么做 |
| --- | --- | --- |
| a | 要求说全了的功能 | 开工，正文带用得上的做法 |
| r、r2 | 界面重做、架构改动 | 直接开工，正文写明这一轮只出方案、不实现；回复一句，不问要不要开始 |
| c | 改了代码的交回，证据充分 | 先 say 收口一次，不 done、不 tell；它复查完再 done |
| c3 | 改字的小活交回 | 直接 done，不收口 |
| c4 | 他说过交回的代码不用再复查收口 | 他的规矩盖过默认：直接 done |
| u2 | 界面成品的截图满是模板痕迹 | read 打开图，say 带百分制分数与具体扣分处，不 done、不 tell |

长程剧本里的会话只会答收口那一问（`ScriptedSession.answerClosing`）；挑刺与对照标准的别的追问它答不了，那几件到剧本结束可能没收尾，靠它们收尾的判定记"不计"。比完成数时把这一层算进去。

## 成绩单

改系统提示、工具、记忆前后，短场景、长程、多日各跑两遍（Pi + sonnet · medium），每遍一个目录，再比（用法与输出在 `score.py` 头注释）：

```bash
python3 apple/scripts/score.py /tmp/cue-eval/base-short-{1,2} /tmp/cue-eval/base-long-{1,2} /tmp/cue-eval/base-days-{1,2} \
  --vs /tmp/cue-eval/new-short-{1,2} /tmp/cue-eval/new-long-{1,2} /tmp/cue-eval/new-days-{1,2}
```

- 整理场景 `m整理钉着的记忆` 的自动检查只确认有回复与记忆产物；运行后用 `python3 apple/scripts/memory-judge.py RUN [RUN…]` 验收合并、回复、语义保留与新原则，全部通过才算完成。它沿用 `bench.py` 的判分模型配置，原文与逐项理由在每遍的 `memory-judge.json`，也能重判旧经过；不把逐字相同或关键词命中当作语义正确。判分语义以脚本的 `RUBRIC` 为准，旧经过中的期望文字不覆盖实际输入。
- 改判分规范时，先把旧分数和原始经过另存，再在副本上重判，保留前后理由。用固定材料核对同义表达、交换句序同判，以及删通过条件、反转免询问、免 lint、仅运行不要求通过均被拒绝；原材料只写“先跑”而丢失“通过”的也应判失败。对照放临时目录，不用重跑产品来覆盖旧失败；真实输出若丢项仍不通过。
- 判定的类别见 `CheckKind`，出错调用的分法见 `CallFailure`；前提这一遍没出现的判定记"不计"，不进通过数。
- 判定按工具调用、库里的结果、会话收到的命令（替他答了哪个选项看会话收到的作答）与消息字段判；只能读 Cue 写的字的几处收在 `EvalReading`，认法与边界在那里，改了认法先拿现有的 .md 重放一遍、看翻了哪些。
- 打扰 = tell（不含 ask、撤回、放回）+ task leave（他收到"待回复"）+ 其他推送（管理器写的 urgent，如出错）；回他的话不算。
- 回复与 tell 超两句按系统提示的上限数；他问进展的那一轮上限是两句与件数（非空的行）里大的那个。
- 怎么看：先看组内差（同一设置几遍之间最大减最小），差值没超过它的不算改动的效果；再看翻转、组内不稳与每遍都没过的。改了判定的措辞，它在成绩单里就是另一条（按措辞认身份），改前改后各列一次。
- 多日另记合并（按摘要认）：在哪一轮、哪一步、几条摘要、之后视图几行，见 .md 的「多日」；单列的轮另出一表。

记忆工具改身份或区间引用时，核对原始调用中的 UUID 与 `range` 是否从输入原样复制，并检查工具结果及库内命中对象；不能只凭最终回复判通过。旧数字身份不再接受；摘要写回与展开绑定生成输入的范围指纹。竞态验收用隔离库走真实 MCP，覆盖输入变化拒绝、未变及区间外追加成功，再跑模型场景。大块指纹还绑定实际读到的子摘要及其输入依赖；子块改写必须使旧父缓存与在途父写失效，相同文本重写不失效。输入就绪才发布范围，子块写入回执接续父块；核对模型确实使用回执的新输入与引用。

## 记忆基准

改 Cue 的提示词或 recall 前后各跑一遍，用 LongMemEval（`lme`）、LoCoMo（`locomo`）、ConvoMem（`convomem`）给长期记忆打分（抽题、判分在 `bench.py` 头注释，每题怎么跑在 `CueEvalBenchTests` 头注释）：

```bash
B=locomo
python3 apple/scripts/bench.py sample $B
TEST_RUNNER_CUEPAD_BENCH_DATA=~/Library/Caches/cuepad-bench/$B/sample.jsonl TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=pi TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/$B-after \
  CUEPAD_TEST_TIME_LIMIT=7200 apple/scripts/xc.sh test mac -only-testing:CuePadTests/CueEvalBenchTests
python3 apple/scripts/bench.py judge /tmp/cue-eval/$B-before /tmp/cue-eval/$B-after
```

- 改提示词时在 sample 上挑改法，在留出集（`sample $B --holdout`）上验。
- `TEST_RUNNER_CUEPAD_BENCH_ONLY=<题号,…>` 只跑几题，`_LANES` 同时跑几题（缺省 8，一遍约四五分钟）。重判一题先删掉它 .json 里的 `label`。大脑那边一遍之间差几题，结论看两遍以上。
