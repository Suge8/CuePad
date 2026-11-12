#!/usr/bin/env bash
# Cue 的真模型评测入口：把每套场景的套件、时限与环境变量收在一处，实际跑的仍是 xc.sh test mac。
# 用法：cue-eval.sh <short|long|days|failover> <输出目录> [xcodebuild 参数…]
#       cue-eval.sh bench <输出目录> <lme|locomo|convomem> [xcodebuild 参数…]   题目先用 bench.py sample 抽好；CUEPAD_BENCH_DATA 换题目文件（如留出集）
#   short     短场景（CueEvalTests）；只跑几个场景就带 -only-testing:'CuePadTests/CueEvalTests/<函数名>()'
#   long      长程（CueEvalLongTests，十分钟左右）：同时跑 CUEPAD_CUE_EVAL_RUNS 遍（缺省 2），第 n 遍写到"输出目录-n"
#   days      多日记忆（CueEvalDaysTests，十分钟左右）：一次一遍
#   failover  换大脑（CueEvalFailoverTests）：换上的那家缺省 codex，不能是 pi
#   bench     记忆基准（CueEvalBenchTests）
# 大脑用 CUEPAD_CUE_EVAL_RUNTIME 选（缺省 pi），换模型与强度的变量见 EvalBrain 头注释，照样带 TEST_RUNNER_ 前缀传。
# 比成绩用 score.py；记忆基准抽题与判分用 bench.py，只跑几题、同时跑几题用 CUEPAD_BENCH_ONLY=<题号,…>、_LANES（缺省 8，同样带前缀）。
set -euo pipefail
[ $# -ge 2 ] || { sed -n '2,11p' "$0" >&2; exit 2; }
mode=$1 out=$2; shift 2
runtime=${CUEPAD_CUE_EVAL_RUNTIME:-pi} extra=()
case $mode in
  short) suite=CueEvalTests limit=900 extra=(-parallel-testing-enabled YES) ;;
  long) suite=CueEvalLongTests limit=3600 extra=(-parallel-testing-enabled YES)
    export TEST_RUNNER_CUEPAD_CUE_EVAL_RUNS=${CUEPAD_CUE_EVAL_RUNS:-2} ;;
  days) suite=CueEvalDaysTests limit=1700 ;;
  failover) suite=CueEvalFailoverTests limit=900 runtime=${CUEPAD_CUE_EVAL_RUNTIME:-codex} ;;
  bench) suite=CueEvalBenchTests limit=7200
    export TEST_RUNNER_CUEPAD_BENCH_DATA="${CUEPAD_BENCH_DATA:-$HOME/Library/Caches/cuepad-bench/${1:?bench 要基准名}/sample.jsonl}"; shift ;;
  *) sed -n '2,11p' "$0" >&2; exit 2 ;;
esac
case " $* " in *" -only-testing:"*) ;; *) extra+=("-only-testing:CuePadTests/$suite") ;; esac
export TEST_RUNNER_CUEPAD_CUE_EVAL=1 TEST_RUNNER_CUEPAD_CUE_EVAL_RUNTIME="$runtime" TEST_RUNNER_CUEPAD_CUE_EVAL_OUT="$out"
export CUEPAD_TEST_TIME_LIMIT=${CUEPAD_TEST_TIME_LIMIT:-$limit}
exec "$(dirname "$0")/xc.sh" test mac "${extra[@]}" "$@"
