#!/usr/bin/env bash
# 用法：xc.sh perf launch mac [次数=5] [启动参数…]   启动参数原样传给 App
#   冷启动到首屏：每次全新进程、从种子克隆的库，打开的是库里记着的那一页（没记的是 Cue 页）。量 exec 成 CuePad 起到进 main、主窗口上屏、
#   首屏内容出来、能交互的墙钟毫秒，与到那一刻主线程、整个进程执行的指令（百万）和主线程的 CPU 毫秒（口径见 LaunchBench.swift），
#   每次一行 LAUNCH-ROW {json}，最后列中位数。
#   种子：CUEPAD_PERF_SEED=<库目录>（如真实库的只读副本，先用这个构建打开一次，免得量进升级库结构）；没给时先写一份演示库
#   （-CuePadDemo YES，就绪后结束，留在 apple/.derived-perf/Build/library-launch-seed），之后每次从它克隆、不带演示参数（演示参数会在启动时写库）。
#   后台量（不抢前台）：墙钟随机器忙闲变，每行带当时的 1 分钟负载；前后对比新旧检出交替跑，以主线程的指令数为准、墙钟看中位数。
#   CUEPAD_TRACE=<xctrace 模板>（如 'Time Profiler'）：每次按 PID 录 trace，App 进 main 就停着等开录（-CuePadTraceWait），
#   存 apple/.derived-perf/Build/traces/launch-<第几次>.trace；录着的那几次时刻不和不录的比。
# xc.sh 构建好 Release（同 perf-mac.sh）后调这里，第一个参数是 CuePad.app。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_trace.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_trace.sh"
APP="$1" runs="${3:-5}"
args=("${@:4}")
[ "$2" = mac ] || { echo "perf launch 只有 mac" >&2; exit 2; }
DERIVED="$(dirname "$(dirname "$(dirname "$APP")")")"

launch() {
  local library="$1"; shift
  exec python3 "$APPLE_DIR/scripts/app.py" exec "$APP" "$library" -- "$@"
}

seed="${CUEPAD_PERF_SEED:-}"
if [ -z "$seed" ]; then
  seed="$DERIVED/library-launch-seed"
  if [ ! -f "$seed/cuepad.db" ]; then
    rm -rf "$seed" && mkdir -p "$seed"
    ready="$DERIVED/launch-seed-ready"
    rm -f "$ready"
    CUEPAD_SHOT_READY="$ready" launch "$seed" -CuePadDemo YES >/dev/null 2>&1 &
    pid=$!
    python3 "$APPLE_DIR/scripts/app.py" wait "$ready" "$pid" 120 >/dev/null || { kill -TERM "$pid" 2>/dev/null; wait "$pid" || true; rm -rf "$seed"; echo "演示库没写完" >&2; exit 1; }
    kill -TERM "$pid"
    wait "$pid" || true
  fi
fi

# App 写 `AWAIT trace <PID>` 时按 PID 开录（_trace.sh），其余行原样转出
relay() {
  local line
  while IFS= read -r line; do
    case "$line" in "AWAIT trace "*) trace_attach "${line#AWAIT trace }" "$trace" & ;; *) printf '%s\n' "$line" ;; esac
  done
  wait
}

library="$DERIVED/library-launch" out="$DERIVED/launch-run.log" pipe="$DERIVED/launch-run.fifo"
rows="$DERIVED/launch.jsonl"
: >"$rows"
for run in $(seq "$runs"); do
  rm -rf "$library" "$pipe"
  cp -cR "$seed" "$library"
  tracing=()
  if [ -n "${CUEPAD_TRACE:-}" ]; then
    mkdir -p "$DERIVED/traces"
    trace="$DERIVED/traces/launch-$run.trace"
    rm -rf "$trace" "$trace.log"
    echo "trace：$trace" >&2
    tracing=(-CuePadTraceWait YES)
  fi
  mkfifo "$pipe"
  relay <"$pipe" >"$out" &
  reader=$!
  launch "$library" -CuePadBench launch ${tracing[@]+"${tracing[@]}"} ${args[@]+"${args[@]}"} >"$pipe" 2>/dev/null &
  pid=$!
  status=0
  wait "$pid" || status=$?
  wait "$reader"
  # 时刻减去 exec 成 CuePad 的那一刻（app.py exec 记在本检出的锁记录里，rusage.py 同口径）
  python3 - "$APPLE_DIR/scripts" "$out" "$status" <<'PY' | tee -a "$rows"
import json, os, sys
sys.path.insert(0, sys.argv[1])
from app_env import SLOT
out, status = sys.argv[2], int(sys.argv[3])
line = next((l for l in open(out) if l.startswith("LAUNCH ")), None)
if line is None or status != 0:
    sys.exit(f"CuePad 没量完（退出码 {status}）：{open(out).read()[-500:]}")
raw = json.loads(line[len("LAUNCH "):])
exec_at = json.load(open(SLOT))["execAt"]
ms = lambda t: round((t - exec_at) / 1e6)
row = {k: ms(raw[k]) for k in ("entry", "window", "content", "interactive")}
row |= {k: raw[k] for k in raw if k.endswith(("MainM", "AllM", "CPUMs"))}
row["long"] = [[ms(a), round((b - a) / 1e6)] for a, b in raw["long"]]
row["load"] = round(os.getloadavg()[0])
print("LAUNCH-ROW " + json.dumps(row, ensure_ascii=False))
PY
done
rm -rf "$library" "$out" "$pipe"
python3 - "$rows" <<'PY'
import json, statistics as st, sys
rows = [json.loads(l[len("LAUNCH-ROW "):]) for l in open(sys.argv[1])]
moments = ("entry", "window", "content", "interactive")
for k in [*moments, *(m + metric for metric in ("MainM", "AllM", "CPUMs") for m in moments), "load"]:
    print(f"{k:26}{st.median(r[k] for r in rows):>10}   各次 {[r[k] for r in rows]}")
PY
