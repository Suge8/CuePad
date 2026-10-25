#!/usr/bin/env bash
# 用法：xc.sh perf idle <mac|ios> [次数=3] [秒=30] [启动参数…]   启动参数原样传给 App，如 -CuePadScene cue
#   空闲与常驻开销：每次全新进程、全新的演示库（给了 CUEPAD_PERF_SEED=<库目录> 时从那份库克隆，如真实库的只读副本），
#   等就绪后至少静置 CUEPAD_IDLE_SETTLE 秒（默认 5，iOS 演示库首启那条"做完了"的提示 5 秒后收起），再等启动后的收尾做完（rusage.py 的 wait_quiet），
#   量接下来 <秒> 内的唤醒、指令、CPU、能耗与内存（口径见 rusage.py），各次取中位数。
#   Mac 实例同所有本机构建在后台（窗口排在最后，不抢前台）；iOS 在领到的模拟器上，每次先重开机（同 perf-ios.sh）。
#   CUEPAD_IDLE_BACKGROUND=1（仅 ios）：就绪后切到设置 App，量 CuePad 进后台之后的开销。
#   CUEPAD_TRACE=<xctrace 模板>（如 'Time Profiler'、Allocations）：量的窗口里同时录 trace，存本检出的 apple/.derived-perf/Build/traces/idle-<平台>-<第几次>.trace；
#   iOS 录的是整机（模拟器里的进程 xctrace 按 PID、按名字都认不出），按打印的 PID 筛。
# xc.sh 构建好 Release（同 perf-mac.sh，产物在 apple/.derived-perf）后调这里，第一个参数是 CuePad.app。不独占机器：量的都是进程自己的内核记账。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_sim.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_sim.sh"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
APP="$1" platform="$2" runs="${3:-3}" seconds="${4:-30}"
args=("${@:5}")
settle="${CUEPAD_IDLE_SETTLE:-5}"
derived="$(dirname "$(dirname "$(dirname "$APP")")")"
BUNDLE_ID=$CUEPAD_APP_ID
if [ "$platform" = ios ]; then
  udid="$(sim_udid "${CUEPAD_IOS_DEVICE:-iPhone 17}")"
  # 每次从刚开机的模拟器量（理由见 perf-ios.sh）
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  sim_boot "$udid"
  xcrun simctl install "$udid" "$APP"
fi
mkdir -p "$derived/traces"
rows="$derived/idle.jsonl"
: >"$rows"
for run in $(seq "$runs"); do
  library="$derived/library-idle" ready="$derived/idle-ready"
  rm -rf "$library" "$ready"
  library_args=(-CuePadDemo YES)
  if [ -n "${CUEPAD_PERF_SEED:-}" ]; then cp -cR "$CUEPAD_PERF_SEED" "$library"; library_args=(); else mkdir -p "$library"; fi
  launch=(${library_args[@]+"${library_args[@]}"} ${args[@]+"${args[@]}"})
  hooks=()
  if [ "$platform" = mac ]; then
    # app.py exec 占住本检出那一份 Mac 实例后 exec 成 CuePad：$! 就是 CuePad
    CUEPAD_SHOT_READY="$ready" python3 "$APPLE_DIR/scripts/app.py" exec "$APP" "$library" -- ${launch[@]+"${launch[@]}"} >/dev/null 2>&1 &
    pid=$!
    stop() { kill -TERM "$pid"; wait "$pid" || true; }
  else
    pid="$(SIMCTL_CHILD_CUEPAD_LIBRARY_DIR="$library" SIMCTL_CHILD_CUEPAD_SHOT_READY="$ready" \
      xcrun simctl launch "$udid" "$BUNDLE_ID" ${launch[@]+"${launch[@]}"} | sed 's/.*: //')"
    stop() { xcrun simctl terminate "$udid" "$BUNDLE_ID" || true; }
    if [ -n "${CUEPAD_IDLE_BACKGROUND:-}" ]; then hooks+=(--on-ready "xcrun simctl launch $udid com.apple.Preferences"); fi
  fi
  if [ -n "${CUEPAD_TRACE:-}" ]; then
    trace="$derived/traces/idle-$platform-$run.trace"
    rm -rf "$trace"
    target="--attach $pid"; [ "$platform" = mac ] || target="--device $udid --all-processes"
    hooks+=(--during "xcrun xctrace record --template $(printf %q "$CUEPAD_TRACE") $target --time-limit ${seconds}s --output $(printf %q "$trace")")
    echo "trace：${trace}（CuePad PID ${pid}）" >&2
  fi
  python3 "$APPLE_DIR/scripts/rusage.py" "$pid" "$ready" "$settle" "$seconds" ${hooks[@]+"${hooks[@]}"} >>"$rows" || { stop; exit 1; }
  stop
done
rm -rf "$derived/library-idle"
python3 - "$rows" <<'PY'
import json, statistics as st, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
for k in rows[0]:
    print(f"{k:14}{st.median(r[k] for r in rows):>10}   各次 {[r[k] for r in rows]}")
PY
