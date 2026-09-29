#!/usr/bin/env bash
# 用法：xc.sh <build|test|shot> <mac|ios> [截图输出路径]
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$APPLE_DIR/.derived"
BUNDLE_ID=com.sugeh.cuepad
IOS_DEVICE="${CUEPAD_IOS_DEVICE:-iPhone 17}"

cmd="${1:-}"; platform="${2:-}"; out="${3:-$DERIVED/shot-$platform.png}"

case "$platform" in
  mac) destination='platform=macOS,arch=arm64'; products="$DERIVED/Build/Products/Debug" ;;
  ios) destination="platform=iOS Simulator,name=$IOS_DEVICE"; products="$DERIVED/Build/Products/Debug-iphonesimulator" ;;
  *) echo "用法：$0 <build|test|shot> <mac|ios> [截图输出路径]" >&2; exit 2 ;;
esac
app="$products/CuePad.app"

mkdir -p "$DERIVED"
[ -f "$DERIVED/.gitignore" ] || echo '*' > "$DERIVED/.gitignore"

xcb() {
  xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad \
    -destination "$destination" -derivedDataPath "$DERIVED" "$@"
}

# 在 pid 进程的窗口里找主窗口（layer 0）的 CGWindowID；没有则输出空。
window_id() {
  osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = Number(argv[0]);
  const list = ObjC.deepUnwrap(ObjC.castRefToObject(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, $.kCGNullWindowID)));
  const w = list.find(w => w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0 && w.kCGWindowBounds.Width > 100);
  return w ? String(w.kCGWindowNumber) : '';
}
JXA
}

shot_mac() {
  mkdir -p "$(dirname "$out")"
  pkill -f "$app/Contents/MacOS/CuePad" 2>/dev/null || true
  # -g：后台启动，不抢当前焦点
  # 库放进 .derived：不碰真实资料库，也不导入 Electron 旧库
  open -g -n --env CUEPAD_LIBRARY_DIR="$DERIVED/library" "$app"
  local pid="" wid="" i
  for i in $(seq 100); do
    pid="$(pgrep -f "$app/Contents/MacOS/CuePad" | head -1 || true)"
    [ -n "$pid" ] && wid="$(window_id "$pid")"
    [ -n "$wid" ] && break
    sleep 0.1
  done
  [ -n "$wid" ] || { echo "10 秒内没有出现 CuePad 窗口" >&2; [ -z "$pid" ] || kill "$pid"; exit 1; }
  screencapture -x -o -l "$wid" "$out"
  # SIGTERM 走应用的正常退出流程
  kill -TERM "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  echo "$out"
}

shot_ios() {
  mkdir -p "$(dirname "$out")"
  local booted_here=0
  if ! xcrun simctl list devices booted | grep -q "$IOS_DEVICE"; then
    xcrun simctl boot "$IOS_DEVICE"; booted_here=1
  fi
  xcrun simctl bootstatus "$IOS_DEVICE" -b >/dev/null
  xcrun simctl install "$IOS_DEVICE" "$app"
  xcrun simctl launch "$IOS_DEVICE" "$BUNDLE_ID" >/dev/null
  sleep 1.5 # 等首帧：simctl 没有渲染完成的通知
  xcrun simctl io "$IOS_DEVICE" screenshot "$out" >/dev/null
  xcrun simctl terminate "$IOS_DEVICE" "$BUNDLE_ID"
  [ "$booted_here" = 0 ] || xcrun simctl shutdown "$IOS_DEVICE"
  echo "$out"
}

case "$cmd" in
  build) xcb -quiet build ;;
  test) xcb test ;;
  shot) xcb -quiet build; "shot_$platform" ;;
  *) echo "用法：$0 <build|test|shot> <mac|ios> [截图输出路径]" >&2; exit 2 ;;
esac
