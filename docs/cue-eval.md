# Cue 评测

要量一处改动（系统提示、工具说明、信封、记忆）对 Cue 做法的影响时，在同一套场景里比改前改后真模型的做法。

## 三套场景

```bash
apple/scripts/cue-eval.sh short /tmp/cue-eval/new-short-1   # 另有 long、days、failover、bench，用法在脚本头注释
```

- 只改了一两类行为时，短场景可只跑受影响的几个（带 `-only-testing`），结论照样看两遍以上。
- 这一遍的系统提示在 `system-prompt.md`。有场景没过时非零退出，输出照样写完。每个场景的库留在 `<场景>.library`，用 `CUEPAD_SHOT_LIBRARY=<它> xc.sh shot mac out.png -- -CuePadScene cue` 看。
- 开销是大脑自报的 token 与费用。缓存跨场景命中一小时，先后跑的缓存读写会不同。
- 做事的标准不在 Cue 的系统提示里，在各家读的规则文件里。

## 换大脑

`cue-eval.sh failover <输出目录>`：Pi 额度用完、自动换到这台 Mac 上另一家真的 Agent 之后，那家能不能起来接着答。

## 会话在问问题：一张表

表与各格的判定在 `CueEvalTests+Asked.swift` 头注释；一遍 14 个场景（`问-<事>-<放行>-<谁的一轮>`）。看一格过没过把三种事合起来数，结论看三遍以上：模型同一格几遍之间会有一两次不同。

## 成绩单

短场景、长程、多日每组各跑两遍，改前改后用同一套大脑与模型（成绩单的「大脑」一行列出各遍用的），每遍一个目录，再比：

```bash
python3 apple/scripts/score.py /tmp/cue-eval/base-short-{1,2} /tmp/cue-eval/base-long-{1,2} /tmp/cue-eval/base-days-{1,2} \
  --vs /tmp/cue-eval/new-short-{1,2} /tmp/cue-eval/new-long-{1,2} /tmp/cue-eval/new-days-{1,2}
```

- 整理场景 `m-整理钉着的记忆` 的自动检查只确认有回复与记忆产物，过没过用 `python3 apple/scripts/memory-judge.py RUN [RUN…]` 判。
- 长程剧本里的会话答不了挑刺的追问：那几件到剧本结束可能没收尾，靠它们收尾的判定记"不计"。比完成数时把这一层算进去。
- 怎么看：差值没超过组内差的不算改动的效果；再看翻转、组内不稳与每遍都没过的。改了判定的措辞，它在成绩单里就是另一条，改前改后各列一次。

评记忆工具的身份或区间引用（规则在 `CueMemoryRange`、`CueStore+CueMemory` 的注释）看原始调用：UUID 与 `range` 是否从输入原样复制，工具结果与库内命中的是哪一条；最终回复看不出来。

## 记忆基准

要量提示词或 recall 的改动对长期记忆的影响时，改前改后各跑一遍，用 LongMemEval（`lme`）、LoCoMo（`locomo`）、ConvoMem（`convomem`）给长期记忆打分：

```bash
B=locomo
python3 apple/scripts/bench.py sample $B
apple/scripts/cue-eval.sh bench /tmp/cue-eval/$B-after $B
python3 apple/scripts/bench.py judge /tmp/cue-eval/$B-before /tmp/cue-eval/$B-after
```

- 改提示词时在 sample 上挑改法，在留出集上验：`bench.py sample $B --holdout` 抽好，跑 `cue-eval.sh bench` 时带 `CUEPAD_BENCH_DATA=~/Library/Caches/cuepad-bench/$B/holdout.jsonl`。
- `TEST_RUNNER_CUEPAD_BENCH_ONLY=<题号,…>` 只跑几题，`_LANES` 同时跑几题（缺省 8 时一遍约四五分钟）。重判一题先删掉它 .json 里的 `label`。大脑那边一遍之间差几题，结论看两遍以上。
