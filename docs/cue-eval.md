# Cue 评测

改 Cue 的系统提示、工具说明、信封或记忆前后各跑一遍，比同一套场景里真模型的做法。

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

- 只改了一两类行为时，短场景可用 `-only-testing:'CuePadTests/CueEvalTests/<函数名>()'` 只跑受影响的几个，结论照样看两遍以上。
- 这一遍的系统提示在 `system-prompt.md`。有场景没过时非零退出，输出照样写完。每个场景的库留在 `<场景>.library`，用 `CUEPAD_SHOT_LIBRARY=<它> xc.sh shot mac out.png -- -CuePadScene cue` 看。
- 开销是大脑自报的 token 与费用。缓存跨场景命中一小时，先后跑的缓存读写会不同。
- 做事的标准不在 Cue 的系统提示里（在各家读的规则文件里，全局规则空着时文件页给起步规则）。评测里 Cue 派的会话照真实的搭：由 CuePad 开的（能从 CuePad 结束）。

## 换大脑

Pi 额度用完、自动换到这台 Mac 上另一家真的 Agent 之后，那家能不能起来接着答（`CueEvalFailoverTests`）。换上的那家用 `_RUNTIME` 选，不能是 Pi：

```bash
TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=codex TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/failover CUEPAD_TEST_TIME_LIMIT=900 \
  apple/scripts/xc.sh test mac -only-testing:CuePadTests/CueEvalFailoverTests
```

## 会话在问问题：一张表

表与各格的判定在 `CueEvalTests+Asked.swift` 头注释；一遍 14 个场景（`问-<事>-<放行>-<谁的一轮>`）。看一格过没过把三种事合起来数，结论看三遍以上：模型同一格几遍之间会有一两次不同。

## 成绩单

改系统提示、工具、记忆前后，短场景、长程、多日各跑两遍（Pi + sonnet · medium），每遍一个目录，再比：

```bash
python3 apple/scripts/score.py /tmp/cue-eval/base-short-{1,2} /tmp/cue-eval/base-long-{1,2} /tmp/cue-eval/base-days-{1,2} \
  --vs /tmp/cue-eval/new-short-{1,2} /tmp/cue-eval/new-long-{1,2} /tmp/cue-eval/new-days-{1,2}
```

- 整理场景 `m-整理钉着的记忆` 的自动检查只确认有回复与记忆产物；运行后用 `python3 apple/scripts/memory-judge.py RUN [RUN…]` 验收，全部通过才算完成。
- 改判分规范时，先把旧分数和原始经过另存，再在副本上重判，保留前后理由。用固定材料核对同义表达、交换句序同判，以及删通过条件、反转免询问、免 lint、仅运行不要求通过均被拒绝；原材料只写“先跑”而丢失“通过”的也应判失败。对照放临时目录，不用重跑产品来覆盖旧失败；真实输出若丢项仍不通过。
- 长程剧本里的会话答不了挑刺的追问：那几件到剧本结束可能没收尾，靠它们收尾的判定记"不计"。比完成数时把这一层算进去。
- 怎么看：差值没超过组内差的不算改动的效果；再看翻转、组内不稳与每遍都没过的。改了判定的措辞，它在成绩单里就是另一条，改前改后各列一次。
- 多日另记合并：见 .md 的「多日」；单列的轮另出一表。

记忆工具改身份或区间引用时（规则在 `CueMemoryRange`、`CueStore+CueMemory` 的注释），核对原始调用中的 UUID 与 `range` 是否从输入原样复制，并检查工具结果及库内命中对象；不能只凭最终回复判通过。竞态验收用隔离库走真实 MCP，覆盖输入变化拒绝、未变及区间外追加成功，再跑模型场景；核对模型确实使用子块写入回执的新输入与引用。

## 记忆基准

改 Cue 的提示词或 recall 前后各跑一遍，用 LongMemEval（`lme`）、LoCoMo（`locomo`）、ConvoMem（`convomem`）给长期记忆打分：

```bash
B=locomo
python3 apple/scripts/bench.py sample $B
TEST_RUNNER_CUEPAD_BENCH_DATA=~/Library/Caches/cuepad-bench/$B/sample.jsonl TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME=pi TEST_RUNNER_CUEPAD_CUE_EVAL_OUT=/tmp/cue-eval/$B-after \
  CUEPAD_TEST_TIME_LIMIT=7200 apple/scripts/xc.sh test mac -only-testing:CuePadTests/CueEvalBenchTests
python3 apple/scripts/bench.py judge /tmp/cue-eval/$B-before /tmp/cue-eval/$B-after
```

- 改提示词时在 sample 上挑改法，在留出集（`sample $B --holdout`）上验。
- `TEST_RUNNER_CUEPAD_BENCH_ONLY=<题号,…>` 只跑几题，`_LANES` 同时跑几题（缺省 8 时一遍约四五分钟）。重判一题先删掉它 .json 里的 `label`。大脑那边一遍之间差几题，结论看两遍以上。
