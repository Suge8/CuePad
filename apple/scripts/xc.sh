#!/usr/bin/env bash
# 用法：xc.sh check                 快速静态门：lint.sh、CuePadKit 的 swift build、iOS 编译；不跑测试
#       xc.sh <build|shot> <mac|ios|ipad> [截图输出路径] [-- 启动参数…]
#       xc.sh rec <ios|ipad> [录屏输出路径.mov] [-- 启动参数…]   同 shot 摆好画面后录屏 CUEPAD_REC_SECONDS 秒（默认 12），看动效与状态切换
#       xc.sh run mac [-- 启动参数…]   同 shot 的隔离实例在后台跑着（给 bcu 操作），就绪后打印 PID；RUN_MAC_TTL 秒后自己退出，下次 run/shot 先结束它
#       xc.sh test <mac|ios|ipad> [xcodebuild 参数…]   参数原样透传，如收窄：-only-testing:CuePadTests/SuiteName
#       xc.sh test kit [swift test 参数…]   CuePadKit 的 swift test（macOS），如 --filter SuiteName
#       xc.sh perf <mac|ios> [参数…]   单次交互的性能测量（perf-mac.sh、perf-ios.sh，参数见各自头注释），独占机器
#       xc.sh release <mac|ios>   发布（mac：公证 zip 与 appcast 替换到 GitHub Release，可加 --dry-run 只出本地产物；ios：上传 TestFlight）；xc.sh device  开发构建装到连接的真机
#       xc.sh provision           开通标识、能力、证书与描述文件；前提见 docs/release.md
# 产物目录固定是本检出的 apple/.derived（Kit 是 CuePadKit/.build）：每个检出一份增量。同一检出的任务排队、性能测量独占机器、
# iOS 任务从固定的一小池模拟器里领一台、任务最多跑 30 分钟（_lock.sh），排队时打印在等谁。
# Agent 直接调 xcodebuild、swift build/test、simctl 开关机会被拦（.pi/extensions/xc-guard.ts）。
# build/test/shot 一律用本机 ad-hoc 签名（不联网、不需要账号）；凭据文件在时 xcodebuild 仍带上 API 密钥参数。
# 提交钩子在 apple/scripts/hooks（主检出只收合并，其余检出跑 lint.sh），每个仓库启用一次、所有检出共享：git config core.hooksPath apple/scripts/hooks
# ios 是 iPhone 模拟器（机型 CUEPAD_IOS_DEVICE，默认 iPhone 17），ipad 是 iPad 模拟器（CUEPAD_IPAD_DEVICE，默认 iPad Pro 11-inch (M5)）；build/test 两者共用同一份模拟器产物。
# 模拟器开着复用（_sim.sh）；每次装新包，资料库与偏好用隔离目录。
# test 里每个测试最多 TEST_TIME_LIMIT 秒（xcodebuild 的测试时限，Xcode 27 实测对 Swift Testing 也生效，主线程死锁也会被结束）：
# 超时的测试记一条 "Time limit was exceeded"，测试宿主重启后接着跑，最后非零退出。
# shot 的启动参数原样传给 App（如 `-- -CuePadDemo YES -CuePadScene editor -theme dark`）；
# CUEPAD_SHOT_LIBRARY 指定隔离资料库目录（默认 .derived/library；隔离库内含偏好设置；相对路径按当前目录解析）。
# shot 不靠固定等待：Debug 构建摆好画面、读库结果到齐、动画停下后写一个就绪标记文件（CUEPAD_SHOT_READY，见 DebugScene.signalReady），这里等它出现再截图。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
# shellcheck source=_sim.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_sim.sh"
# shellcheck source=_lock.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_lock.sh"
absolute() { case "$1" in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
DERIVED="$APPLE_DIR/.derived"
BUNDLE_ID=com.sugeh.cuepad
IOS_DEVICE="${CUEPAD_IOS_DEVICE:-iPhone 17}"
IPAD_DEVICE="${CUEPAD_IPAD_DEVICE:-iPad Pro 11-inch (M5)}"
# 正常的测试几秒内跑完，最慢的也不到一分钟；挂住的测试曾让测试宿主停了 34 分钟没人发现
TEST_TIME_LIMIT=120
# run mac 的实例活多久：够一轮 bcu 交互验收；忘了收的实例曾活过 14 小时
RUN_MAC_TTL=3600
USAGE="用法：$0 <check|build|test|shot|rec|run|perf|release|device|provision> [mac|ios|ipad|kit] …（见脚本头注释）"

cmd="${1:-}"; platform="${2:-}"
case "$cmd" in
  release)
    # 发布的产物必须对应一个提交：工作区里别人或自己没提交的改动会被一起打进包
    if [ -n "$(git -C "$APPLE_DIR" status --porcelain --untracked-files=no)" ]; then
      echo "工作区有没提交的改动，不发布；在干净的检出里发" >&2; exit 1
    fi
    case "$platform" in
      mac) exec "$APPLE_DIR/scripts/release-mac.sh" "${@:3}" ;;
      ios) exec "$APPLE_DIR/scripts/release-ios.sh" testflight ;;
      *) echo "用法：$0 release <mac|ios>" >&2; exit 2 ;;
    esac ;;
  device) exec "$APPLE_DIR/scripts/release-ios.sh" device ;;
  provision) exec python3 "$APPLE_DIR/scripts/provision.py" "${2:-all}" "${@:3}" ;;
  perf)
    case "$platform" in
      mac|ios) exec "$APPLE_DIR/scripts/perf-$platform.sh" "${@:3}" ;;
      *) echo "用法：$0 perf <mac|ios> [参数…]" >&2; exit 2 ;;
    esac ;;
  test|shot|rec) case "$platform" in ios|ipad) xc_enter sim "$0" "$@" ;; *) xc_enter plain "$0" "$@" ;; esac ;;
  check|build|run) xc_enter plain "$0" "$@" ;;
esac
if [ "$cmd" = test ] && [ "$platform" = kit ]; then
  cd "$APPLE_DIR/CuePadKit" && exec swift test "${@:3}"
fi
[ "$cmd" != check ] || platform=ios
if [ "$cmd" = rec ]; then out="${3:-$DERIVED/rec-$platform.mov}"; else out="${3:-$DERIVED/shot-$platform.png}"; fi
launch_args=()
if [ "$#" -gt 3 ] && [ "$4" = "--" ]; then launch_args=("${@:5}"); fi
if [ "$cmd" = run ] && [ "${3:-}" = "--" ]; then launch_args=("${@:4}"); fi

mkdir -p "$DERIVED"
case "$platform" in
  mac) destination='platform=macOS,arch=arm64'; products="$DERIVED/Build/Products/Debug" ;;
  ios|ipad)
    if [ "$platform" = ios ]; then model="$IOS_DEVICE"; else model="$IPAD_DEVICE"; fi
    device="$(sim_udid "$model")"
    destination="platform=iOS Simulator,id=$device"; products="$DERIVED/Build/Products/Debug-iphonesimulator" ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
app="$products/CuePad.app"

# 本机模式：ad-hoc 签名。工程默认是团队 + 自动签名（给发布用），iCloud 这类受限能力在 ad-hoc 下无法启动，
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
  local ready=$1 alive=$2
  for _ in $(seq 600); do
    [ -f "$ready" ] && return 0
    $alive || { echo "截图前 App 退出了" >&2; return 1; }
    sleep 0.1
  done
  echo "60 秒内画面没有就绪（没有写下 ${ready}）" >&2
  return 1
}

# 后台启动隔离的 Debug 实例，PID 记进 pidfile、留在 pid（调用方先设好 ready 与 pidfile）。
start_mac() {
  local exe="$app/Contents/MacOS/CuePad"
  rm -f "$ready"
  # 上次被中断的截图或 run 留下的实例：只结束记录下的那个 PID，并确认它仍是这个产物目录里的 CuePad
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile")"
    if [ "$(ps -o comm= -p "$pid" 2>/dev/null)" = "$exe" ]; then
      kill -TERM "$pid"
      for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
      # 5 秒没退出（卡在收尾里）：PID 已核对是自己的实例，强制结束，不无限等
      if kill -0 "$pid" 2>/dev/null; then echo "上一个实例 $pid 5 秒没退出，强制结束" >&2; kill -KILL "$pid"; fi
    fi
    rm -f "$pidfile"
  fi
  # 直接启动可执行文件以拿到确切 PID；App 见到 CUEPAD_SHOT_READY 就在后台跑、窗口排在最后，不抢当前焦点也不盖住别的窗口
  # 库与各 Agent 的目录都隔离：不碰真实资料库、不读 ~/.pi 的会话、接入 Agent 不写进真实的配置目录
  # （socket 路径受 sun_path 104 字节限制，放 /tmp）
  CUEPAD_LIBRARY_DIR="$(absolute "${CUEPAD_SHOT_LIBRARY:-$DERIVED/library}")" CUEPAD_SHOT_READY="$ready" \
    PI_CODING_AGENT_DIR="$DERIVED/pi-agent" CUEPAD_BIN_DIR="$DERIVED/bin" CUEPAD_PI_SOCKET_DIR="/tmp/cuepad-shot-$(id -u)" \
    CLAUDE_CONFIG_DIR="$DERIVED/agents/claude" CODEX_HOME="$DERIVED/agents/codex" OPENCODE_CONFIG_DIR="$DERIVED/agents/opencode" \
    "$exe" ${launch_args[@]+"${launch_args[@]}"} >"$DERIVED/shot-mac.log" 2>&1 &
  pid=$!
  echo "$pid" > "$pidfile"
}

run_mac() {
  local ready="$DERIVED/shot-ready" pidfile="$DERIVED/shot-mac.pid" pid=""
  start_mac
  wait_ready "$ready" "kill -0 $pid" || { kill -TERM "$pid" 2>/dev/null; rm -f "$pidfile"; exit 1; }
  # 到点自己退出：守护进程脱离本脚本（不占检出锁、不随脚本结束），到时只结束仍是这个可执行文件的那个 PID
  # shellcheck disable=SC2016 # 由里层 bash 展开
  nohup bash -c 'sleep "$1"; [ "$(ps -o comm= -p "$2")" != "$3" ] || kill -TERM "$2"' _ "$RUN_MAC_TTL" "$pid" "$app/Contents/MacOS/CuePad" >/dev/null 2>&1 &
  echo "$pid"
}

shot_mac() {
  mkdir -p "$(dirname "$out")"
  local ready="$DERIVED/shot-ready" pidfile="$DERIVED/shot-mac.pid" pid="" wid=""
  start_mac
  for _ in $(seq 100); do
    wid="$(window_id "$pid")"
    [ -n "$wid" ] && break
    sleep 0.1
  done
  [ -n "$wid" ] || { echo "10 秒内没有出现 CuePad 窗口" >&2; kill -TERM "$pid"; rm -f "$pidfile"; exit 1; }
  wait_ready "$ready" "kill -0 $pid" || { kill -TERM "$pid" 2>/dev/null; rm -f "$pidfile"; exit 1; }
  # 摆画面时可能换了窗口（settings 画面收起主窗口、拍设置窗口）：按就绪时屏上的窗口再取一次
  wid="$(window_id "$pid")"
  screencapture -x -o -l "$wid" "$out"
  # SIGTERM 走应用的正常退出流程
  kill -TERM "$pid"
  wait "$pid" || true
  rm -f "$pidfile"
  echo "$out"
}

# iOS/iPadOS：库与偏好放进隔离目录（每个设备各一个，默认 .derived/library-<ios|ipad>），启动参数原样传给 App。
# simctl 用 SIMCTL_CHILD_ 前缀把环境变量传给模拟器里的进程。装上这次的包、摆好画面后截图（shot）或录屏（rec），再结束 App；模拟器开着留给下一次。
capture_sim() {
  mkdir -p "$(dirname "$out")"
  sim_boot "$device"
  xcrun simctl install "$device" "$app"
  local ready="$DERIVED/shot-ready-$platform"
  rm -f "$ready"
  SIMCTL_CHILD_CUEPAD_LIBRARY_DIR="$(absolute "${CUEPAD_SHOT_LIBRARY:-$DERIVED/library-$platform}")" SIMCTL_CHILD_CUEPAD_SHOT_READY="$ready" \
    xcrun simctl launch "$device" "$BUNDLE_ID" ${launch_args[@]+"${launch_args[@]}"} >/dev/null
  wait_ready "$ready" "sim_alive" || { xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null; exit 1; }
  if [ "$cmd" = rec ]; then
    # recordVideo 收到 SIGINT 才把文件写完整；只结束这里启动的那个 PID。录多久是要录的内容，固定等
    xcrun simctl io "$device" recordVideo --codec h264 --force "$out" 2>/dev/null &
    local recorder=$!
    sleep "${CUEPAD_REC_SECONDS:-12}"
    kill -INT "$recorder"
    wait "$recorder" || true
  else
    xcrun simctl io "$device" screenshot "$out" >/dev/null
  fi
  xcrun simctl terminate "$device" "$BUNDLE_ID"
  echo "$out"
}
# 先取全文再找：pipefail 下 grep -q 提前退出会让前面的命令吃 SIGPIPE，整条判成失败
sim_alive() { local list; list="$(xcrun simctl spawn "$device" launchctl list 2>/dev/null)"; [[ "$list" == *"UIKitApplication:$BUNDLE_ID"* ]]; }
shot_ios() { capture_sim; }
shot_ipad() { capture_sim; }

case "$cmd" in
  check)
    "$APPLE_DIR/scripts/lint.sh"
    (cd "$APPLE_DIR/CuePadKit" && swift build --quiet)
    xcb -quiet build ;;
  build) xcb -quiet build ;;
  test)
    limits=(-test-timeouts-enabled YES -maximum-test-execution-time-allowance "$TEST_TIME_LIMIT")
    # 先开好领到的模拟器（停用 PosterBoard，见 _sim.sh），xcodebuild 就用开着的这台
    if [ -n "${device:-}" ]; then sim_boot "$device"; fi
    # iOS/iPad：同一个入口也在模拟器上跑 CuePadKit 的测试（iOS 编辑器等只在这里跑；macOS 上的 Kit 测试是 test kit）。
    # 带了收窄参数（-only-testing 等）时只跑 App 那部分；两部分都跑完再按其一失败退出。
    status=0
    xcb test "${limits[@]}" "${@:3}" || status=$?
    if [ "$platform" != mac ] && [ "$#" -le 2 ]; then
      (cd "$APPLE_DIR/CuePadKit" && xcodebuild test -scheme CuePadKit-Package -destination "$destination" -derivedDataPath "$DERIVED/kit-$platform" "${limits[@]}" 2>&1) \
        | { grep -v 'failed with exit code 0 but produced no further output' || true; } || status=$?
    fi
    exit $status ;;
  shot) xcb -quiet build; "shot_$platform" ;;
  rec) [ "$platform" != mac ] || { echo "rec 只有 ios、ipad：Mac 的动效与 iOS 同一份代码，在模拟器里录" >&2; exit 2; }; xcb -quiet build; capture_sim ;;
  run) [ "$platform" = mac ] || { echo "run 只有 mac：iOS 模拟器没有可操作的窗口，用 shot" >&2; exit 2; }; xcb -quiet build; run_mac ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
