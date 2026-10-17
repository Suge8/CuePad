#!/usr/bin/env bash
# 用法：xc.sh check                 快速静态门：lint.sh、CuePadKit 的 swift build、iOS 编译；不跑测试
#       xc.sh <build|shot> <mac|ios|ipad> [截图输出路径] [-- 启动参数…]
#       xc.sh rec <ios|ipad|mac> [录屏输出路径.mov] [-- 启动参数…]   同 shot 摆好画面后录屏 CUEPAD_REC_SECONDS 秒（默认 12），看动效与状态切换；
#         CUEPAD_REC_LAUNCH=1 从启动前开录（冷启动的首屏），录满秒数不等就绪（只有 ios、ipad）。Mac 按窗口录（winrec.swift，ScreenCaptureKit），
#         不录屏幕区域：别的窗口、系统的录屏标记都不进画面
#       xc.sh run mac [-- 启动参数…]   同 shot 的隔离实例在后台跑着（给 bcu 操作），就绪后打印 PID；RUN_MAC_TTL 秒后自己退出，本机任一检出的下次 run/shot 先结束它（同一时间只有一个 Mac 调试实例）
#       xc.sh test <mac|ios|ipad> [xcodebuild 参数…]   参数原样透传，如收窄：-only-testing:CuePadTests/SuiteName
#       xc.sh test kit [swift test 参数…]   CuePadKit 的 swift test（macOS），如 --filter SuiteName
#       xc.sh perf <mac|ios> [参数…]   单次交互的性能测量（perf-mac.sh、perf-ios.sh，参数见各自头注释），独占机器
#       xc.sh perf idle <mac|ios> [次数] [秒] [启动参数…]   空闲与常驻开销：启动到就绪、唤醒、指令、CPU、能耗、内存（perf-idle.sh），独占机器
#       xc.sh release <mac|ios>   发布（mac：公证 zip 与 appcast 替换到 GitHub Release，可加 --dry-run 只出本地产物；ios：上传 TestFlight）；xc.sh device  开发构建装到连接的真机
#       xc.sh provision           开通标识、能力、证书与描述文件；前提见 docs/release.md
# 产物目录固定是本检出的 apple/.derived（Kit 是 CuePadKit/.build）：每个检出一份增量。同一检出的任务排队、性能测量独占机器、
# iOS 任务从固定的一小池模拟器里领一台、任务最多跑 30 分钟（_lock.sh），排队时打印在等谁。
# Agent 直接调 xcodebuild、swift build/test、simctl 开关机会被拦（.pi/extensions/xc-guard.ts）。
# build/test/shot 一律用本机 ad-hoc 签名（不联网、不需要账号）；凭据文件在时 xcodebuild 仍带上 API 密钥参数。
# 例外：CUEPAD_SIGN=development 时 Mac 用 Apple Development 证书与「CuePad macOS Development」描述文件签名、写定 CloudKit 开发环境，
# 只给同步测量（docs/verify.md「同步测量」）；描述文件要先登记这台 Mac（provision.py device <Provisioning UDID> <名称> MAC_OS，再 provision.py profiles）。
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
# 本机同一时间只留一个 Mac 调试实例（不分检出）：各检出各记一份时，并行的截图、测量在 Dock 里堆出一排 CuePad
MAC_PIDFILE="/tmp/cuepad-shot-$(id -u)/mac.pid"
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
      mac|ios|idle) exec "$APPLE_DIR/scripts/perf-$platform.sh" "${@:3}" ;;
      *) echo "用法：$0 perf <mac|ios|idle> [参数…]" >&2; exit 2 ;;
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

# CUEPAD_SIGN=development：ad-hoc 构建完只给主程序换签名（嵌入描述文件、带 iCloud 权限并写定开发环境）。不在 xcodebuild 里换：
# 签名设置覆盖到每个 target，框架与命令行工具会要团队、bundle id；内嵌的仍是 ad-hoc，没开 Hardened Runtime 就照常加载。
sign_development() {
  [ "${CUEPAD_SIGN:-}" = development ] || return 0
  [ "$platform" = mac ] || { echo "CUEPAD_SIGN=development 只用于 mac" >&2; exit 2; }
  python3 "$APPLE_DIR/scripts/provision.py" unlock
  local profile entitlements="$DERIVED/CuePad-macOS-development.entitlements" decoded="$DERIVED/profile.plist"
  profile="$(for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile; do
    security cms -D -i "$f" > "$decoded" 2>/dev/null && [ "$(plutil -extract Name raw "$decoded")" = "CuePad macOS Development" ] && echo "$f"; done | head -1)"
  [ -n "$profile" ] || { echo "没有「CuePad macOS Development」描述文件：先 provision.py profiles" >&2; exit 1; }
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  cp "$APPLE_DIR/App/Config/CuePad-macOS.entitlements" "$entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Development" \
    -c "Add :com.apple.application-identifier string $CUEPAD_TEAM_ID.$BUNDLE_ID" -c "Add :com.apple.developer.team-identifier string $CUEPAD_TEAM_ID" "$entitlements"
  # 证书只认专用钥匙串里那份（描述文件按它建）；登录钥匙串里可能有同名的另一张
  codesign --force --keychain "$HOME/.appstoreconnect/cuepad-signing.keychain-db" --sign "Apple Development" --entitlements "$entitlements" "$app"
}

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
  # 上一个调试实例（任一检出的截图或 run）：只结束记录下的那个 PID，并确认它仍是某个检出产物目录里的 CuePad，不碰正式版
  mkdir -p "$(dirname "$pidfile")"
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile")"
    if [[ "$(ps -o comm= -p "$pid" 2>/dev/null)" == */.derived/Build/Products/Debug/CuePad.app/Contents/MacOS/CuePad ]]; then
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
  local ready="$DERIVED/shot-ready" pidfile="$MAC_PIDFILE" pid=""
  start_mac
  wait_ready "$ready" "kill -0 $pid" || { kill -TERM "$pid" 2>/dev/null; rm -f "$pidfile"; exit 1; }
  # 到点自己退出：守护进程脱离本脚本（不占检出锁、不随脚本结束），到时只结束仍是这个可执行文件的那个 PID
  # shellcheck disable=SC2016 # 由里层 bash 展开
  nohup bash -c 'sleep "$1"; [ "$(ps -o comm= -p "$2")" != "$3" ] || kill -TERM "$2"' _ "$RUN_MAC_TTL" "$pid" "$app/Contents/MacOS/CuePad" >/dev/null 2>&1 &
  echo "$pid"
}

shot_mac() {
  mkdir -p "$(dirname "$out")"
  local ready="$DERIVED/shot-ready" pidfile="$MAC_PIDFILE" pid="" wid=""
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
  check_shot_size "$out" "$ready"
  echo "$out"
}

# 截到的图比就绪文件里窗口的像素尺寸（DebugScene.shotSize）小一截：窗口在屏上被系统缩放显示（调度中心、台前调度开着），
# screencapture 拍下的是缩小的画面。删掉、报错，不留一张看着像成果的小图。
# 差 2% 以内不算：就绪之后窗口还可能按内容长几个点（设置窗口），缩放显示差的是一半上下。
check_shot_size() {
  local shot=$1 expected got
  expected="$(cat "$2")"
  got="$(sips -g pixelWidth -g pixelHeight "$shot" | awk '/pixelWidth/{w=$2} /pixelHeight/{h=$2} END{print w" "h}')"
  awk -v g="$got" -v e="$expected" 'BEGIN { split(g, a, " "); split(e, b, " "); exit !(a[1] >= b[1] * 0.98 && a[2] >= b[2] * 0.98) }' && return 0
  rm -f "$shot"
  echo "截到 ${got/ /×}，窗口是 ${expected/ /×}：窗口在屏上被缩放显示（调度中心或台前调度开着？），关掉再拍" >&2
  exit 1
}

# Mac 录屏：同 shot 摆好画面，按窗口录 CUEPAD_REC_SECONDS 秒（winrec.swift，录前按源码编译一次放在产物目录），录完结束实例。
rec_mac() {
  mkdir -p "$(dirname "$out")"
  local ready="$DERIVED/shot-ready" pidfile="$MAC_PIDFILE" pid="" recorder="$DERIVED/winrec" width height
  if [ ! -x "$recorder" ] || [ "$APPLE_DIR/scripts/winrec.swift" -nt "$recorder" ]; then
    swiftc -O "$APPLE_DIR/scripts/winrec.swift" -o "$recorder"
  fi
  start_mac
  wait_ready "$ready" "kill -0 $pid" || { kill -TERM "$pid" 2>/dev/null; rm -f "$pidfile"; exit 1; }
  # 就绪文件没有换行，read 读到文件尾返回非零
  read -r width height <"$ready" || true
  local status=0
  "$recorder" "$pid" "${CUEPAD_REC_SECONDS:-12}" "$width" "$height" "$out" || status=$?
  kill -TERM "$pid"
  wait "$pid" || true
  rm -f "$pidfile"
  exit $status
}

# iOS/iPadOS：库与偏好放进隔离目录（每个设备各一个，默认 .derived/library-<ios|ipad>），启动参数原样传给 App。
# simctl 用 SIMCTL_CHILD_ 前缀把环境变量传给模拟器里的进程。装上这次的包、摆好画面后截图（shot）或录屏（rec），再结束 App；模拟器开着留给下一次。
capture_sim() {
  mkdir -p "$(dirname "$out")"
  sim_boot "$device"
  xcrun simctl install "$device" "$app"
  local ready="$DERIVED/shot-ready-$platform" recorder=""
  rm -f "$ready"
  # recordVideo 收到 SIGINT 才把文件写完整；只结束这里启动的那个 PID。录多久是要录的内容，固定等
  record() { xcrun simctl io "$device" recordVideo --codec h264 --force "$out" 2>/dev/null & recorder=$!; }
  stop_recording() { sleep "${CUEPAD_REC_SECONDS:-12}"; kill -INT "$recorder"; wait "$recorder" || true; }
  # 冷启动录屏：录像先起来（约半秒后才出帧）再启动 App，录满秒数、不等就绪
  local cold=""
  if [ "$cmd" = rec ] && [ -n "${CUEPAD_REC_LAUNCH:-}" ]; then cold=1; record; sleep 1; fi
  SIMCTL_CHILD_CUEPAD_LIBRARY_DIR="$(absolute "${CUEPAD_SHOT_LIBRARY:-$DERIVED/library-$platform}")" SIMCTL_CHILD_CUEPAD_SHOT_READY="$ready" \
    xcrun simctl launch "$device" "$BUNDLE_ID" ${launch_args[@]+"${launch_args[@]}"} >/dev/null
  if [ -n "$cold" ]; then
    stop_recording
  else
    wait_ready "$ready" "sim_alive" || { xcrun simctl terminate "$device" "$BUNDLE_ID" 2>/dev/null; exit 1; }
    if [ "$cmd" = rec ]; then record; stop_recording; else xcrun simctl io "$device" screenshot "$out" >/dev/null; fi
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
  build) xcb -quiet build; sign_development ;;
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
  rec) xcb -quiet build; if [ "$platform" = mac ]; then rec_mac; else capture_sim; fi ;;
  run) [ "$platform" = mac ] || { echo "run 只有 mac：iOS 模拟器没有可操作的窗口，用 shot" >&2; exit 2; }; xcb -quiet build; run_mac ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
