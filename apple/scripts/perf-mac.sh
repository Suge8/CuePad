#!/usr/bin/env bash
# 用法：xc.sh perf mac [次数=3] [启动参数…]   启动参数原样传给 App，如只量几项：xc.sh perf mac 3 -CuePadInteractOnly 会话页,长文打字·回复框
#   单次交互：演示库与大库（-CuePadSeed perf：50 项目、5000 卡、300 张大图、200 个 Pi 历史会话，前 12 个带长对话）上的 -CuePadBench interact，
#   逐项量点击回合（动作发出到画面第一次变的主线程 CPU 毫秒）、合计、最重一圈、指令数与掉帧，取各次的中位数，
#   与交互预算（docs/verify.md「交互预算」）比较并列成表；有一项超了就以 1 退出。
#   -CuePadInteractOnly 项,项 只量列出的几项（前后对比省下整套流程），用法见 docs/verify.md。
# xc.sh 构建好 Release（带 DEBUG 条件，只为留下测量代码；预算按用户拿到的构建定，产物在 apple/.derived-perf，Instruments 也用这份）、
# 独占机器（别的编译、测试同时跑，指令数之外的数都会被拖歪）后调这里，第一个参数是 CuePad.app。iOS 的单次交互见 perf-ios.sh。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
runs="${2:-3}"
extra=("${@:3}")
DERIVED="$(dirname "$(dirname "$(dirname "$APP")")")"
LIBRARY="$DERIVED/library-perf"

# 实例经 app.py exec（隔离、占住本检出那一份后 exec 成 CuePad）：后台调用时 $! 就是 CuePad
launch() {
  local library="$1"; shift
  exec python3 "$APPLE_DIR/scripts/app.py" exec "$APP" "$library" -- "$@"
}

# 第一次：写入大库并把大项目设为当前项目，写完结束；之后的运行才是冷启动
if [ ! -f "$LIBRARY/cuepad.db" ]; then
  mkdir -p "$LIBRARY"
  launch "$LIBRARY" -CuePadSeed perf -CuePadProject 大项目 >"$DERIVED/seed.log" 2>&1 &
  pid=$!
  until [ "$(sqlite3 "$LIBRARY/cuepad.db" 'SELECT count(*) FROM piSessions' 2>/dev/null || echo 0)" = 200 ]; do
    kill -0 "$pid" 2>/dev/null || { echo "写入大库时 CuePad 退出了，见 $DERIVED/seed.log" >&2; exit 1; }
    sleep 1
  done
  kill -TERM "$pid"
  wait "$pid" || true
fi

# 每次都是全新进程（首访就是首访）与一份没量过的库：量的动作会写库（发送），同一份库连跑，后几次量的是越来越长的对话。
# 演示库每次重建；大库每次从写好的那份 APFS 克隆（不占时间也不占空间）
collect() {
  local label="$1" source="$2" library="$DERIVED/library-run"; shift 2
  for _ in $(seq "$runs"); do
    rm -rf "$library"
    if [ -n "$source" ]; then cp -cR "$source" "$library"; fi
    launch "$library" "$@" -CuePadBench interact -CuePadWindowSize 1440x900 ${extra[@]+"${extra[@]}"} 2>/dev/null | sed -n 's/^INTERACT //p' | sed "s/^{/{\"库\":\"$label\",/"
  done
  rm -rf "$library"
}
rows="$DERIVED/interact.jsonl"
: >"$rows"
collect 演示库 "" -CuePadDemo YES -CuePadProject 圆桌 >>"$rows"
collect 大库 "$LIBRARY" -CuePadProject 大项目 >>"$rows"
python3 - "$rows" <<'PY'
import json, statistics as st, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
order = []
for row in rows:
    key = (row["库"], row["name"])
    if key not in order:
        order.append(key)
over = 0
print(f"{'库':6}{'交互':14}{'点击回合 ms':>12}{'预算':>7}{'合计 ms':>9}{'指令 M':>8}{'最重一圈':>9}{'掉帧':>6}{'预算':>6}{'最长帧 ms':>10}  结果")
for key in order:
    samples = [r for r in rows if (r["库"], r["name"]) == key]
    click = st.median(r["clickMs"] for r in samples)
    hitches = st.median(r["hitches"] for r in samples)
    worst = max(r["worstMs"] for r in samples)
    total = st.median(r["totalMs"] for r in samples)
    instructions = st.median(r["instructionsM"] for r in samples)
    heaviest = st.median(r["maxTurnMs"] for r in samples)
    budget_click, budget_hitches = samples[0]["budgetClickMs"], samples[0]["budgetHitches"]
    ok = click <= budget_click and hitches <= budget_hitches
    over += not ok
    unseen = '，未见变化' if not all(r["seen"] for r in samples) else ''
    print(f"{key[0]:6}{key[1]:14}{click:12.1f}{budget_click:7.0f}{total:9.0f}{instructions:8.0f}{heaviest:9.1f}{hitches:6.0f}{budget_hitches:6d}{worst:10.1f}  {'ok' if ok else '超预算'}{unseen}")
sys.exit(1 if over else 0)
PY
