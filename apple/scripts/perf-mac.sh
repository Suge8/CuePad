#!/usr/bin/env bash
# 用法：perf-mac.sh [次数=3]
# 在合成大库（-CuePadSeed perf：50 项目、5000 卡、300 张大图、200 个 Pi 历史会话）上跑 -CuePadBench perf，
# 每次输出一行 JSON：冷启动到首屏、内存、滚动与开合纸页的帧间隔、⌘K 搜索延迟。说明见 docs/development.md「性能测量」。
# 构建是打开了编译优化的 Debug（测量代码只在 Debug 里，未优化的 SwiftUI 慢得多、数字没有意义），产物在 ${CUEPAD_DERIVED:-apple/.derived}-perf。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="${CUEPAD_DERIVED:-$APPLE_DIR/.derived}-perf"
LIBRARY="$DERIVED/library-perf"
EXE="$DERIVED/Build/Products/Debug/CuePad.app/Contents/MacOS/CuePad"
runs="${1:-3}"

mkdir -p "$DERIVED"
[ -f "$DERIVED/.gitignore" ] || echo '*' > "$DERIVED/.gitignore"
# 本机 ad-hoc 签名；关掉 hardened runtime，否则 ad-hoc 签名的进程加载不了别家团队签名的 Sparkle
xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" -quiet build \
  DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CUEPAD_MAC_ENTITLEMENTS=App/Config/CuePad-macOS-local.entitlements \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule GCC_OPTIMIZATION_LEVEL=s ENABLE_HARDENED_RUNTIME=NO \
  >"$DERIVED/build.log" 2>&1 || { tail -30 "$DERIVED/build.log" >&2; exit 1; }

# exec：在后台调用时 $! 就是 CuePad 本身，结束它不会留下进程
launch() {
  CUEPAD_LIBRARY_DIR="$LIBRARY" PI_CODING_AGENT_DIR="$DERIVED/pi-agent" CUEPAD_PI_SOCKET_DIR="/tmp/cuepad-perf-$(id -u)" \
    exec "$EXE" -piExtensionDeclined YES "$@"
}

# 第一次：写入大库并把大项目设为当前项目，写完结束；之后的运行才是冷启动
if [ ! -f "$LIBRARY/cuepad.db" ]; then
  mkdir -p "$LIBRARY"
  launch -CuePadSeed perf -CuePadProject 大项目 >"$DERIVED/seed.log" 2>&1 &
  pid=$!
  until [ "$(sqlite3 "$LIBRARY/cuepad.db" 'SELECT count(*) FROM piSessions' 2>/dev/null || echo 0)" = 200 ]; do
    kill -0 "$pid" 2>/dev/null || { echo "写入大库时 CuePad 退出了，见 $DERIVED/seed.log" >&2; exit 1; }
    sleep 1
  done
  kill -TERM "$pid"
  wait "$pid" || true
fi

for _ in $(seq "$runs"); do
  launch -CuePadBench perf -CuePadWindowSize 1440x900 2>/dev/null | sed -n 's/^PERF //p'
done
