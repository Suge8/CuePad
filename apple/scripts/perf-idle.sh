#!/usr/bin/env bash
# 用法：xc.sh perf idle <mac|ios> [次数=3] [秒=30] [启动参数…]   启动参数原样传给 App，如 -CuePadScene cue
#   空闲与常驻开销：每次全新进程、全新的演示库（给了 CUEPAD_PERF_SEED=<库目录> 时从那份库克隆，如真实库的只读副本），
#   等就绪后静置 CUEPAD_IDLE_SETTLE 秒（默认 5），量接下来 <秒> 内的唤醒、指令、CPU、能耗与内存（口径见 rusage.py），各次取中位数。
#   Mac 实例在后台（给了 CUEPAD_SHOT_READY，窗口排在最后，不抢前台）；iOS 在每次重开机的 0 号模拟器上（同 perf-ios.sh）。
#   CUEPAD_IDLE_BACKGROUND=1（仅 ios）：就绪后切到设置 App，量 CuePad 进后台之后的开销。
#   CUEPAD_TRACE=<xctrace 模板>（如 'Time Profiler'、Allocations）：量的窗口里同时录 trace，存 /tmp/cuepad-perf/idle-<平台>-<第几次>.trace。
# 独占机器（_lock.sh）。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_lock.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_lock.sh"
# shellcheck source=_sim.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_sim.sh"
# shellcheck source=_perf.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_perf.sh"
xc_enter exclusive "$0" "$@"
platform="${1:-}" runs="${2:-3}" seconds="${3:-30}"
args=("${@:4}")
settle="${CUEPAD_IDLE_SETTLE:-5}"
BUNDLE_ID=com.sugeh.cuepad
case "$platform" in
  mac) derived="$PERF_MAC_DERIVED"; perf_build mac ;;
  ios)
    derived="$PERF_IOS_DERIVED" udid="$(sim_udid "${CUEPAD_IOS_DEVICE:-iPhone 17}")"
    perf_build ios "$udid"
    # 每次从刚开机的模拟器量（理由见 perf-ios.sh）
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    sim_boot "$udid"
    xcrun simctl install "$udid" "$PERF_IOS_APP" ;;
  *) echo "用法：xc.sh perf idle <mac|ios> [次数] [秒] [启动参数…]" >&2; exit 2 ;;
esac
mkdir -p /tmp/cuepad-perf
rows="$derived/idle.jsonl"
: >"$rows"
for run in $(seq "$runs"); do
  library="$derived/library-idle" ready="$derived/idle-ready"
  rm -rf "$library" "$ready"
  helpers=()
  library_args=(-CuePadDemo YES)
  if [ -n "${CUEPAD_PERF_SEED:-}" ]; then cp -cR "$CUEPAD_PERF_SEED" "$library"; library_args=(); else mkdir -p "$library"; fi
  if [ "$platform" = mac ]; then
    CUEPAD_SHOT_READY="$ready" perf_launch_mac "$library" "${library_args[@]}" ${args[@]+"${args[@]}"} >/dev/null 2>&1 &
    pid=$!
    stop() { kill -TERM "$pid"; wait "$pid" || true; }
  else
    pid="$(SIMCTL_CHILD_CUEPAD_LIBRARY_DIR="$library" SIMCTL_CHILD_CUEPAD_SHOT_READY="$ready" \
      xcrun simctl launch "$udid" "$BUNDLE_ID" "${library_args[@]}" ${args[@]+"${args[@]}"} | sed 's/.*: //')"
    stop() { xcrun simctl terminate "$udid" "$BUNDLE_ID" || true; }
    if [ -n "${CUEPAD_IDLE_BACKGROUND:-}" ]; then
      ( while [ ! -f "$ready" ]; do sleep 0.1; done; xcrun simctl launch "$udid" com.apple.Preferences >/dev/null ) &
      helpers+=($!)
    fi
  fi
  if [ -n "${CUEPAD_TRACE:-}" ]; then
    trace="/tmp/cuepad-perf/idle-$platform-$run.trace"
    rm -rf "$trace"
    device=(); [ "$platform" = mac ] || device=(--device "$udid")
    ( while [ ! -f "$ready" ]; do sleep 0.1; done; sleep "$settle"
      xcrun xctrace record --template "$CUEPAD_TRACE" ${device[@]+"${device[@]}"} --attach "$pid" --time-limit "${seconds}s" --output "$trace" >/dev/null 2>&1 ) &
    helpers+=($!)
  fi
  python3 "$APPLE_DIR/scripts/rusage.py" "$pid" "$ready" "$settle" "$seconds" >>"$rows" || { stop; exit 1; }
  # trace 写完（xctrace 到时限后还要收尾）再结束 App
  for helper in ${helpers[@]+"${helpers[@]}"}; do wait "$helper" || true; done
  stop
done
rm -rf "$derived/library-idle"
python3 - "$rows" <<'PY'
import json, statistics as st, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
for k in rows[0]:
    print(f"{k:14}{st.median(r[k] for r in rows):>10}   各次 {[r[k] for r in rows]}")
PY
