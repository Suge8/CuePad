#!/usr/bin/env bash
# 用法：xc.sh <build|test|shot> <mac|ios|ipad> [截图输出路径] [-- 启动参数…]
#       xc.sh release <mac|ios>   发布（mac：Developer ID 公证 zip；ios：上传 TestFlight）；xc.sh device  开发构建装到连接的真机
#       xc.sh provision           开通标识、能力、证书与描述文件；前提见 apple/README.md「签名与发布」
# build/test/shot 一律用本机 ad-hoc 签名（不联网、不需要账号）；凭据文件在时 xcodebuild 仍带上 API 密钥参数。
# ios 是 iPhone 模拟器（CUEPAD_IOS_DEVICE，默认 iPhone 17），ipad 是 iPad 模拟器（CUEPAD_IPAD_DEVICE，默认 iPad Pro 11-inch (M5)）；build/test 两者共用同一份模拟器产物。
# shot 的启动参数原样传给 App（如 `-- -CuePadDemo YES -CuePadScene editor -theme dark`）；
# CUEPAD_DERIVED 指定产物目录（默认 apple/.derived）；并行的 agent 各用一个，否则同目录的构建与测试会互相覆盖。
# CUEPAD_SHOT_LIBRARY 指定隔离资料库目录（默认 .derived/library；隔离库内含偏好设置；相对路径按当前目录解析），CUEPAD_SHOT_SETTLE 为出窗后等待渲染的秒数。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$APPLE_DIR/scripts/_signing.sh"
absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
DERIVED="$(absolute "${CUEPAD_DERIVED:-$APPLE_DIR/.derived}")"
BUNDLE_ID=com.sugeh.cuepad
IOS_DEVICE="${CUEPAD_IOS_DEVICE:-iPhone 17}"
IPAD_DEVICE="${CUEPAD_IPAD_DEVICE:-iPad Pro 11-inch (M5)}"

cmd="${1:-}"; platform="${2:-}"
case "$cmd" in
  release)
    case "$platform" in
      mac) exec "$APPLE_DIR/scripts/release-mac.sh" "${@:3}" ;;
      ios) exec "$APPLE_DIR/scripts/release-ios.sh" testflight ;;
      *) echo "用法：$0 release <mac|ios>" >&2; exit 2 ;;
    esac ;;
  device) exec "$APPLE_DIR/scripts/release-ios.sh" device ;;
  provision) exec python3 "$APPLE_DIR/scripts/provision.py" "${2:-all}" "${@:3}" ;;
esac
out="${3:-$DERIVED/shot-$platform.png}"
launch_args=()
if [ "$#" -gt 3 ] && [ "$4" = "--" ]; then launch_args=("${@:5}"); fi

case "$platform" in
  mac) destination='platform=macOS,arch=arm64'; products="$DERIVED/Build/Products/Debug" ;;
  ios) device="$IOS_DEVICE"; destination="platform=iOS Simulator,name=$device"; products="$DERIVED/Build/Products/Debug-iphonesimulator" ;;
  ipad) device="$IPAD_DEVICE"; destination="platform=iOS Simulator,name=$device"; products="$DERIVED/Build/Products/Debug-iphonesimulator" ;;
  *) echo "用法：$0 <build|test|shot> <mac|ios|ipad> [截图输出路径] [-- 启动参数…]" >&2; exit 2 ;;
esac
app="$products/CuePad.app"

mkdir -p "$DERIVED"
[ -f "$DERIVED/.gitignore" ] || echo '*' > "$DERIVED/.gitignore"

# 本机模式：ad-hoc 签名。工程默认是团队 + 自动签名（给发布用），iCloud/推送这类受限能力在 ad-hoc 下无法启动，
# 所以日常构建覆盖成不带团队与身份、且用不含这些能力的 macOS 权限文件。
local_signing=(DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CUEPAD_MAC_ENTITLEMENTS=App/Config/CuePad-macOS-local.entitlements)

xcb() {
  xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad \
    -destination "$destination" -derivedDataPath "$DERIVED" ${asc_auth[@]+"${asc_auth[@]}"} "$@" "${local_signing[@]}"
}

# 在 pid 进程的窗口里找主窗口（layer 0、在屏幕上、面积最大）的 CGWindowID；没有则输出空。
window_id() {
  osascript -l JavaScript - "$1" <<'JXA'
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = Number(argv[0]);
  const list = ObjC.deepUnwrap(ObjC.castRefToObject(
    $.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, $.kCGNullWindowID)));
  const area = w => w.kCGWindowBounds.Width * w.kCGWindowBounds.Height;
  const w = list.filter(w => w.kCGWindowOwnerPID === pid && w.kCGWindowLayer === 0 && w.kCGWindowIsOnscreen)
    .sort((a, b) => area(b) - area(a))[0];
  return w ? String(w.kCGWindowNumber) : '';
}
JXA
}

shot_mac() {
  mkdir -p "$(dirname "$out")"
  pkill -f "$app/Contents/MacOS/CuePad" 2>/dev/null || true
  # -g：后台启动，不抢当前焦点
  # 库与 Pi 目录都隔离：不碰真实资料库、不导入 Electron 旧库、不读 ~/.pi 的会话
  # （socket 路径受 sun_path 104 字节限制，放 /tmp）
  open -g -n --env CUEPAD_LIBRARY_DIR="$(absolute "${CUEPAD_SHOT_LIBRARY:-$DERIVED/library}")" \
    --env PI_CODING_AGENT_DIR="$DERIVED/pi-agent" --env CUEPAD_PI_SOCKET_DIR="/tmp/cuepad-shot-$(id -u)" \
    "$app" ${launch_args[@]+--args "${launch_args[@]}"}
  local pid="" wid="" i
  for i in $(seq 100); do
    pid="$(pgrep -f "$app/Contents/MacOS/CuePad" | head -1 || true)"
    [ -n "$pid" ] && wid="$(window_id "$pid")"
    [ -n "$wid" ] && break
    sleep 0.1
  done
  [ -n "$wid" ] || { echo "10 秒内没有出现 CuePad 窗口" >&2; [ -z "$pid" ] || kill "$pid"; exit 1; }
  sleep "${CUEPAD_SHOT_SETTLE:-1.5}" # 等数据读入与首帧：界面没有渲染完成的通知
  screencapture -x -o -l "$wid" "$out"
  # SIGTERM 走应用的正常退出流程
  kill -TERM "$pid"
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  echo "$out"
}

# iOS/iPadOS：库与偏好放进隔离目录（每个设备各一个，默认 .derived/library-<ios|ipad>），启动参数原样传给 App。
# simctl 用 SIMCTL_CHILD_ 前缀把环境变量传给模拟器里的进程。
shot_sim() {
  mkdir -p "$(dirname "$out")"
  local booted_here=0
  if ! xcrun simctl list devices booted | grep -qF "$device ("; then
    xcrun simctl boot "$device"; booted_here=1
  fi
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl install "$device" "$app"
  SIMCTL_CHILD_CUEPAD_LIBRARY_DIR="$(absolute "${CUEPAD_SHOT_LIBRARY:-$DERIVED/library-$platform}")" \
    xcrun simctl launch "$device" "$BUNDLE_ID" ${launch_args[@]+"${launch_args[@]}"} >/dev/null
  sleep "${CUEPAD_SHOT_SETTLE:-1.5}" # 等数据读入与首帧：simctl 没有渲染完成的通知
  xcrun simctl io "$device" screenshot "$out" >/dev/null
  xcrun simctl terminate "$device" "$BUNDLE_ID"
  [ "$booted_here" = 0 ] || xcrun simctl shutdown "$device"
  echo "$out"
}
shot_ios() { shot_sim; }
shot_ipad() { shot_sim; }

case "$cmd" in
  build) xcb -quiet build ;;
  test) xcb test ;;
  shot) xcb -quiet build; "shot_$platform" ;;
  *) echo "用法：$0 <build|test|shot> <mac|ios|ipad> [截图输出路径] [-- 启动参数…]" >&2; exit 2 ;;
esac
