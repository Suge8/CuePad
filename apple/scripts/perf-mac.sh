#!/usr/bin/env bash
# 用法：perf-mac.sh <cold|scenarios|interact> [次数=3]
#   cold       冷启动与整段场景：合成大库（-CuePadSeed perf：50 项目、5000 卡、300 张大图、200 个 Pi 历史会话）上的 -CuePadBench perf，
#              每次一行 JSON：冷启动到首屏、内存、滚动与开合纸页的帧间隔、⌘K 搜索延迟。
#   scenarios  持续场景：同一个大库上的 -CuePadBench scenarios（侧栏切项目、Agent 页滚动、会话滚动与流式、打字、悬停、缩放窗口、⌘K 逐字打），
#              每次一行 JSON，每项的帧间隔与掉帧；库里的会话最好先用 pi-live.py 连到桥上。
#   interact   单次交互：演示库与大库上的 -CuePadBench interact，逐项量点击回合（主线程 CPU 毫秒）与掉帧，取各次的中位数，
#              与交互预算（docs/development.md「交互预算」）比较并列成表；有一项超了就以 1 退出。
# 说明见 docs/development.md「性能测量」。
# cold、scenarios 用打开了编译优化的 Debug 构建（测量代码只在 Debug 里，未优化的 SwiftUI 慢得多、数字没有意义），产物在 ${CUEPAD_DERIVED:-apple/.derived}-perf；
# interact 用 Release（带 DEBUG 条件，只为留下测量代码）：预算按用户拿到的构建定，产物在 ${CUEPAD_DERIVED:-apple/.derived}-perf-release。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-}"
runs="${2:-3}"
case "$mode" in cold | scenarios | interact) ;; *) echo "用法：$0 <cold|scenarios|interact> [次数]" >&2; exit 2 ;; esac

if [ "$mode" = interact ]; then
  DERIVED="${CUEPAD_DERIVED:-$APPLE_DIR/.derived}-perf-release"
  CONFIG=Release
  FLAGS=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG')
else
  DERIVED="${CUEPAD_DERIVED:-$APPLE_DIR/.derived}-perf"
  CONFIG=Debug
  FLAGS=(SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s)
fi
EXE="$DERIVED/Build/Products/$CONFIG/CuePad.app/Contents/MacOS/CuePad"
LIBRARY="$DERIVED/library-perf"

mkdir -p "$DERIVED"
[ -f "$DERIVED/.gitignore" ] || echo '*' > "$DERIVED/.gitignore"
# 本机 ad-hoc 签名；关掉 hardened runtime，否则 ad-hoc 签名的进程加载不了别家团队签名的 Sparkle
xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" -quiet build \
  DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CUEPAD_MAC_ENTITLEMENTS=App/Config/CuePad-macOS-local.entitlements \
  "${FLAGS[@]}" ENABLE_HARDENED_RUNTIME=NO \
  >"$DERIVED/build.log" 2>&1 || { tail -30 "$DERIVED/build.log" >&2; exit 1; }

# exec：在后台调用时 $! 就是 CuePad 本身，结束它不会留下进程
launch() {
  local library="$1"; shift
  CUEPAD_LIBRARY_DIR="$library" PI_CODING_AGENT_DIR="$DERIVED/pi-agent" CUEPAD_PI_SOCKET_DIR="/tmp/cuepad-perf-$(id -u)" \
    exec "$EXE" -piExtensionDeclined YES "$@"
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

if [ "$mode" != interact ]; then
  bench=perf
  [ "$mode" = scenarios ] && bench=scenarios
  for _ in $(seq "$runs"); do
    launch "$LIBRARY" -CuePadBench "$bench" -CuePadWindowSize 1440x900 2>/dev/null | sed -n 's/^PERF //p'
  done
  exit 0
fi

# interact：每次都是全新进程（首访就是首访）；演示库每次重建，大库用同一份
collect() {
  local label="$1"; shift
  for _ in $(seq "$runs"); do
    launch "$@" -CuePadBench interact -CuePadWindowSize 1440x900 2>/dev/null | sed -n 's/^INTERACT //p' | sed "s/^{/{\"库\":\"$label\",/"
  done
}
rows="$DERIVED/interact.jsonl"
: >"$rows"
demo="$DERIVED/library-demo"
rm -rf "$demo"
collect 演示库 "$demo" -CuePadDemo YES -CuePadProject 圆桌 >>"$rows"
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
print(f"{'库':6}{'交互':14}{'点击回合 ms':>12}{'预算':>7}{'掉帧':>6}{'预算':>6}{'最长帧 ms':>10}  结果")
for key in order:
    samples = [r for r in rows if (r["库"], r["name"]) == key]
    click = st.median(r["clickMs"] for r in samples)
    hitches = st.median(r["hitches"] for r in samples)
    worst = max(r["worstMs"] for r in samples)
    budget_click, budget_hitches = samples[0]["budgetClickMs"], samples[0]["budgetHitches"]
    ok = click <= budget_click and hitches <= budget_hitches
    over += not ok
    print(f"{key[0]:6}{key[1]:14}{click:12.1f}{budget_click:7.0f}{hitches:6.0f}{budget_hitches:6d}{worst:10.1f}  {'ok' if ok else '超预算'}")
sys.exit(1 if over else 0)
PY
