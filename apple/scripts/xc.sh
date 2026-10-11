#!/usr/bin/env bash
# 用法：xc.sh <build|shot> <mac|ios|ipad> [截图输出路径] [-- 启动参数…]
#       xc.sh test <mac|ios|ipad> [xcodebuild 参数…]   参数原样透传，如收窄：-only-testing:CuePadTests/SuiteName
#       xc.sh release <mac|ios>   发布（mac：Developer ID 公证 zip；ios：上传 TestFlight）；xc.sh device  开发构建装到连接的真机
#       xc.sh provision           开通标识、能力、证书与描述文件；前提见 docs/release.md
#       xc.sh synclat [--last 3h] [--archive 手机.logarchive]   读同步到达日志，按场景算推送延迟与丢失率（docs/verify.md「同步延迟实测」）
# build/test/shot 一律用本机 ad-hoc 签名（不联网、不需要账号）；凭据文件在时 xcodebuild 仍带上 API 密钥参数。
# ios 是 iPhone 模拟器（CUEPAD_IOS_DEVICE，默认 iPhone 17），ipad 是 iPad 模拟器（CUEPAD_IPAD_DEVICE，默认 iPad Pro 11-inch (M5)）；build/test 两者共用同一份模拟器产物。
# shot 的启动参数原样传给 App（如 `-- -CuePadDemo YES -CuePadScene editor -theme dark`）；
# CUEPAD_DERIVED 指定产物目录（默认 apple/.derived）；并行的 agent 各用一个，否则同目录的构建与测试会互相覆盖。
# CUEPAD_SHOT_LIBRARY 指定隔离资料库目录（默认 .derived/library；隔离库内含偏好设置；相对路径按当前目录解析）。
# shot 不靠固定等待：Debug 构建摆好画面、读库结果到齐、动画停下后写一个就绪标记文件（CUEPAD_SHOT_READY，见 DebugScene.signalReady），这里等它出现再截图。
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
  synclat) exec python3 "$APPLE_DIR/scripts/synclat.py" "${@:2}" ;;
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

# 退出码即 xcodebuild 的退出码（pipefail）。-quiet 下只有警告的编译步骤会被打成
# "error: the following command failed with exit code 0 but produced no further output"——不是失败，滤掉这一行免得误读。
xcb() {
  xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad \
    -destination "$destination" -derivedDataPath "$DERIVED" ${asc_auth[@]+"${asc_auth[@]}"} "$@" "${local_signing[@]}" 2>&1 \
    | { grep -v 'failed with exit code 0 but produced no further output' || true; }
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

# 等 App 写下就绪标记：最多 60 秒；进程先退出（崩溃）就不再等。
wait_ready() {
  local ready=$1 alive=$2 i
  for i in $(seq 600); do
    [ -f "$ready" ] && return 0
    $alive || { echo "截图前 App 退出了" >&2; return 1; }
    sleep 0.1
  done
  echo "60 秒内画面没有就绪（没有写下 ${ready}）" >&2
  return 1
}

shot_mac() {
  mkdir -p "$(dirname "$out")"
  local ready="$DERIVED/shot-ready"
  rm -f "$ready"
  local exe="$app/Contents/MacOS/CuePad" pidfile="$DERIVED/shot-mac.pid" pid="" wid="" i
  # 上次被中断的截图留下的实例：只结束记录下的那个 PID，并确认它仍是这个产物目录里的 CuePad
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile")"
    if [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = "$exe" ]; then
      kill -TERM "$pid"
      while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
    fi
    rm -f "$pidfile"
  fi
  # 直接启动可执行文件以拿到确切 PID；不经 LaunchServices 激活，不抢当前焦点
  # 库与 Pi 目录都隔离：不碰真实资料库、不读 ~/.pi 的会话
  # （socket 路径受 sun_path 104 字节限制，放 /tmp）
  CUEPAD_LIBRARY_DIR="$(absolute "${CUEPAD_SHOT_LIBRARY:-$DERIVED/library}")" CUEPAD_SHOT_READY="$ready" \
    PI_CODING_AGENT_DIR="$DERIVED/pi-agent" CUEPAD_PI_SOCKET_DIR="/tmp/cuepad-shot-$(id -u)" \
    "$exe" ${launch_args[@]+"${launch_args[@]}"} >"$DERIVED/shot-mac.log" 2>&1 &
  pid=$!
  echo "$pid" > "$pidfile"
  for i in $(seq 100); do
    wid="$(window_id "$pid")"
    [ -n "$wid" ] && break
    sleep 0.1
  done
  [ -n "$wid" ] || { echo "10 秒内没有出现 CuePad 窗口" >&2; kill -TERM "$pid"; rm -f "$pidfile"; exit 1; }
  wait_ready "$ready" "kill -0 $pid" || { kill -TERM "$pid" 2>/dev/null; rm -f "$pidfile"; exit 1; }
  screencapture -x -o -l "$wid" "$out"
  # SIGTERM 走应用的正常退出流程
  kill -TERM "$pid"
  wait "$pid" || true
  rm -f "$pidfile"
  echo "$out"
}

# 这个名字的模拟器是否已启动：按设备名整行精确比较（子串匹配会把别人的"critic8 iPhone 18 Pro"当成"iPhone 18 Pro"，并行时装到别人的设备上）。
# 先取全文再比：pipefail 下管道里的 grep -q 提前退出会让前面的命令吃 SIGPIPE
sim_booted() {
  local list names
  list="$(xcrun simctl list devices booted)"
  names="$(sed -nE 's/^ +(.+) \([0-9A-F-]{36}\) \(Booted\) *$/\1/p' <<< "$list")"
  grep -qxF "$1" <<< "$names"
}

# iOS/iPadOS：库与偏好放进隔离目录（每个设备各一个，默认 .derived/library-<ios|ipad>），启动参数原样传给 App。
# simctl 用 SIMCTL_CHILD_ 前缀把环境变量传给模拟器里的进程。
shot_sim() {
  mkdir -p "$(dirname "$out")"
  local booted_here=0
  if ! sim_booted "$device"; then
    xcrun simctl boot "$device"; booted_here=1
  fi
  xcrun simctl bootstatus "$device" -b >/dev/null
  xcrun simctl install "$device" "$app"
  local ready="$DERIVED/shot-ready-$platform"
  rm -f "$ready"
  SIMCTL_CHILD_CUEPAD_LIBRARY_DIR="$(absolute "${CUEPAD_SHOT_LIBRARY:-$DERIVED/library-$platform}")" SIMCTL_CHILD_CUEPAD_SHOT_READY="$ready" \
    xcrun simctl launch "$device" "$BUNDLE_ID" ${launch_args[@]+"${launch_args[@]}"} >/dev/null
  wait_ready "$ready" "sim_alive" || { xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null; exit 1; }
  xcrun simctl io "$device" screenshot "$out" >/dev/null
  xcrun simctl terminate "$device" "$BUNDLE_ID"
  [ "$booted_here" = 0 ] || xcrun simctl shutdown "$device"
  echo "$out"
}
# 先取全文再找：pipefail 下 grep -q 提前退出会让前面的命令吃 SIGPIPE，整条判成失败
sim_alive() { local list; list="$(xcrun simctl spawn "$device" launchctl list 2>/dev/null)"; [[ "$list" == *"UIKitApplication:$BUNDLE_ID"* ]]; }
shot_ios() { shot_sim; }
shot_ipad() { shot_sim; }

case "$cmd" in
  build) xcb -quiet build ;;
  test)
    # xcodebuild 会启动模拟器且不关；本次启动的由脚本关掉，已开着的不动
    if [ -n "${device:-}" ] && ! sim_booted "$device"; then
      trap 'xcrun simctl shutdown "$device" 2>/dev/null || true' EXIT
    fi
    # iOS/iPad：同一个入口也在模拟器上跑 CuePadKit 的测试（iOS 编辑器等只在这里跑；macOS 上的 Kit 测试用 swift test）。
    # 带了收窄参数（-only-testing 等）时只跑 App 那部分；两部分都跑完再按其一失败退出。
    status=0
    xcb test "${@:3}" || status=$?
    if [ "$platform" != mac ] && [ "$#" -le 2 ]; then
      (cd "$APPLE_DIR/CuePadKit" && xcodebuild test -scheme CuePadKit-Package -destination "$destination" -derivedDataPath "$DERIVED/kit-$platform" 2>&1) \
        | { grep -v 'failed with exit code 0 but produced no further output' || true; } || status=$?
    fi
    exit $status ;;
  shot) xcb -quiet build; "shot_$platform" ;;
  *) echo "用法：$0 <build|test|shot> <mac|ios|ipad> [截图输出路径] [-- 启动参数…]" >&2; exit 2 ;;
esac
