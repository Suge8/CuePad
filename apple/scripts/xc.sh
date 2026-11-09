#!/usr/bin/env bash
# CuePad 的构建、测试、截图、测量、发布只走这里（Agent 绕开它直接调 xcodebuild、swift build/test、simctl 开关机，
# 或自己起停 CuePad，会被 .pi/extensions/xc-guard.ts 拦下）。
#   xc.sh check                                     提交前的门：lint.sh、CuePadKit 的 swift build、iOS 编译（连测试目标）、Mac App 连测试目标的整模块编译（只在 Mac 编的测试，如 #if os(macOS) 的，警告也在这里拦）；
#                                                   自己的 Swift 源文件（App、CuePadKit）有一条编译警告就失败，第三方与生成的代码不算（_build.sh 的 own_warnings）
#   xc.sh build <mac|ios|ipad>
#   xc.sh activity-log [输出.json]                  生产 iCloud 活动取证只读导出：签隔离副本、不启动应用服务，不打开真实库、不重启正式版
#   xc.sh strings                                   编 mac 与 ios，把界面文字收进 String Catalog，列出缺英文的（strings.py 头注释）
#   xc.sh test <mac|ios|ipad> [xcodebuild 参数…]     如 -only-testing:CuePadTests/SuiteName；ios、ipad 不带参数时连 CuePadKit 也在模拟器上跑
#   xc.sh test kit [xcodebuild 参数…]               CuePadKit 在 macOS 上的测试，如 -only-testing:CueSyncTests/PendingTests
#     test 只打印编译的警告与错误、失败的用例；收尾一页结论（test_summary.py）：Swift Testing 与 XCTest 各自的通过、失败、跳过数，首个失败（用例、断言原文、文件行），
#       跳过的套件与原因，最慢 5 个，完整日志路径（App 日志、每条用例都在里面：apple/.derived/test.log）。退出码是 xcodebuild 的
#   xc.sh shot <mac|ios|ipad> [图.png] [-- 启动参数…] [, [图.png] [-- 启动参数…]]…
#                                                   构建 → 逐张起隔离实例 → 画面就绪后截窗口 → 退出。一次调用拍一批：一次进锁、一次构建（iOS 还一次装包），
#                                                   张与张之间用单独的 , 隔开；一张失败记下继续，最后列出失败的并非零退出。没写图路径的放 apple/.derived/shot-<平台>/<启动参数的值连起来>.png。例：
#                                                   xc.sh shot ios -- -CuePadScene shelf , dark-cue.png -- -CuePadScene cue -theme dark
#   xc.sh rec  <mac|ios|ipad> [片.mov] [-- 启动参数…] [, …]  同上，每张录 CUEPAD_REC_SECONDS 秒（默认 12）；CUEPAD_REC_LAUNCH=1 从启动前开录（Mac 等窗口出现就录）
#     Mac 首帧入片后写 <片.mov>.ready；交互先清旧回执、等新回执再操作，应用就绪不等于已开录。
#     ios、ipad 的 shot、rec、run 认 -CuePadLandscape YES：起实例前把模拟器横过来（设备的物理朝向，devicectl），这一张拍完转回竖屏（app_sim.py 的 orient）
#   xc.sh run  <mac|ios|ipad> [-- 启动参数…]          起着给 bcu、axe 操作，打印 PID（模拟器另带 UDID）；实例 5 分钟后自己退出（CUEPAD_RUN_SECONDS 改）。
#                                                   iOS 的模拟器由后台看守租着，别的检出领不到，直到实例退出、到时或 stop
#   xc.sh stop                                      结束本检出 run 起的实例（Mac 与模拟器）
#   xc.sh fleet up|status|down|accept               同一个检出里 Mac、iPhone、iPad 三个隔离实例共用一朵模拟云；accept 验收手机建灵感 → Mac 与 iPad 读到（fleet.py 头注释）
#   xc.sh explore [种子] [秒] [-- 启动参数…]           找偶发的主线程卡死：起 iPhone 实例，按种子随机点滑三页，App 的看守记下卡住时连取样本（explore.py 头注释）
#   xc.sh perf <mac|ios> [次数] [启动参数…]            单次交互：点击回合、指令、掉帧（perf-mac.sh、perf-ios.sh）
#   xc.sh perf idle <mac|ios> [次数] [秒] [启动参数…]   静置时的 CPU、指令、唤醒、能耗、内存与启动到就绪（perf-idle.sh）
#   xc.sh perf launch mac [次数] [启动参数…]            冷启动：到主窗口上屏、首屏内容出来、能交互（perf-launch.sh）
#   xc.sh perf ab <旧检出> <新检出> <轮数> <perf 的参数…>   新旧交替跑同一条 perf（含 idle、launch），每轮一行、最后对比表，前台阻塞到结束（perf-ab.py）
#   xc.sh release <mac|ios> | device | provision    发布与签名（docs/release.md）；用到描述文件的那一段全机排队（_lock.sh 规则 3）
# 启动参数原样传给 App（如 -CuePadDemo YES -CuePadScene editor -theme dark；Debug 认的参数见 UI/Debug/DebugScene+Args*.swift 的字段注释，画面见 DebugScene+Scenes.swift）。
# 实例的隔离、每个检出一份、一定退出见 app.py 头注释；排队、在等谁、等待上限、任务时限、结束时的用时行见 _lock.sh；模拟器槽位见 _lock.sh 与 _sim.sh。
# CUEPAD_SHOT_LIBRARY 换隔离库目录（默认 apple/.derived/library[-ios|-ipad]，如真实库的只读副本）。
# 产物目录是本检出的 apple/.derived（perf 的 Release 构建在 apple/.derived-perf，check 的 Mac 整模块编译在 apple/.derived-wmo，Kit 的测试在 apple/.derived/kit-<平台>，check 的 Kit 构建在 CuePadKit/.build）：每个检出一份增量。
# 本机构建一律 ad-hoc 签名（工程默认，见 Signing.xcconfig）；CUEPAD_SIGN=development 只给同步测量（docs/perf.md「同步测量」）。
# 每个测试最多 TEST_TIME_LIMIT 秒（_lock.sh；CUEPAD_TEST_TIME_LIMIT 覆盖，给真模型的评测用，任务时限随它变；Xcode 的测试时限，对 Swift Testing 与主线程死锁也生效）：超时记一条 "Time limit was exceeded"，非零退出。
# Kit 的测试因此也走 xcodebuild：swift test（Swift 6.4）没有测试时限的参数，Swift Testing 的 .timeLimit 只取消测试任务、要等它自己结束，
# 不响应取消的等待会让整个测试进程挂到任务时限。xcodebuild 只把 TEST_RUNNER_ 开头的环境变量交给测试进程（去掉前缀），测试进程的工作目录是 /private/tmp。
# 提交钩子：git config core.hooksPath apple/scripts/hooks（每个仓库一次）。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
[ "${1:-}" != release ] || exec python3 "$APPLE_DIR/scripts/release-context.py" run "${@:2}"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
# shellcheck source=_sim.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_sim.sh"
# shellcheck source=_lock.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_lock.sh"
# shellcheck source=_build.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_build.sh"
# shellcheck source=_test.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_test.sh"
IOS_DEVICE="${CUEPAD_IOS_DEVICE:-iPhone 17}"
IPAD_DEVICE="${CUEPAD_IPAD_DEVICE:-iPad Pro 11-inch (M5)}"
# 测试里条件等待的上限从这个时限推出（CueTestSupport 的 conditionBudget）：测试不另写短的墙钟上限
export TEST_RUNNER_CUEPAD_TEST_TIME_LIMIT=$TEST_TIME_LIMIT
USAGE="用法：$0 <check|build|strings|test|shot|rec|run|stop|fleet|explore|perf|release|device|provision|activity-log> [mac|ios|ipad|kit] …（见脚本头注释）"

cmd="${1:-}"; platform="${2:-}"
case "$cmd" in
  device) exec "$APPLE_DIR/scripts/release-ios.sh" device ;;
  strings) "$0" build mac; "$0" build ios; exec python3 "$APPLE_DIR/scripts/strings.py" sync ;;
  provision) signing_begin; exec python3 "$APPLE_DIR/scripts/provision.py" "${2:-all}" "${@:3}" ;;  # 签名锁见 _lock.sh 规则 3
  stop) exec python3 "$APPLE_DIR/scripts/app.py" stop ;;
  explore) exec python3 "$APPLE_DIR/scripts/explore.py" "$0" "${@:2}" ;;
  fleet) exec python3 "$APPLE_DIR/scripts/fleet.py" "$0" "${@:2}" ;;
  perf) [ "$platform" != ab ] || exec python3 "$APPLE_DIR/scripts/perf-ab.py" "${@:3}" ;;  # 其余先构建、再测量，两段各自进锁（见下）
  test|shot|rec|run)
    # 本检出上一个 run 的实例租着一台模拟器：先收掉再排队，免得槽位被自己占满
    if [ "$cmd" = run ] && [ "$platform" != mac ]; then python3 "$APPLE_DIR/scripts/app.py" stop sim >/dev/null; fi
    case "$platform" in ios) xc_enter "$IOS_DEVICE" "$0" "$@" ;; ipad) xc_enter "$IPAD_DEVICE" "$0" "$@" ;; *) xc_enter "" "$0" "$@" ;; esac ;;
  check|build|build-perf|activity-log) xc_enter "" "$0" "$@" ;;  # build-perf：perf 的构建段，内部用
  *) echo "$USAGE" >&2; exit 2 ;;
esac
[ "$cmd" != check ] || platform=ios
[ "$cmd" != activity-log ] || platform=mac
perf_script=""
if [ "$cmd" = perf ]; then
  # perf idle|launch <平台> …：平台跟着传给 perf-idle.sh、perf-launch.sh
  perf_script="perf-$platform.sh"
  case "$platform" in idle|launch) platform="${3:-}" ;; esac
  case "$platform" in mac|ios) ;; *) echo "用法：$0 perf [idle|launch] <mac|ios> [参数…]" >&2; exit 2 ;; esac
fi

# perf 量的是 Release（带 DEBUG 条件，只为留下测量代码与调试场景）：数要和用户拿到的构建同一档优化
if [ "$cmd" = perf ] || [ "$cmd" = build-perf ]; then
  DERIVED="$APPLE_DIR/.derived-perf"; configuration=Release
  # Release 配置在工程里指定了发布证书，换回 ad-hoc；关掉 hardened runtime：ad-hoc 签名的进程加载不了别家团队签名的 Sparkle
  # shellcheck disable=SC2016 # $(inherited) 由 xcodebuild 展开
  build_settings=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG' CODE_SIGN_IDENTITY=- ENABLE_HARDENED_RUNTIME=NO)
else
  DERIVED="$APPLE_DIR/.derived"; configuration=Debug; build_settings=()
fi
mkdir -p "$DERIVED"
case "$platform" in
  mac) destination='platform=macOS,arch=arm64'; app="$DERIVED/Build/Products/$configuration/CuePad.app" ;;
  kit) [ "$cmd" = test ] || { echo "$USAGE" >&2; exit 2; }; destination='platform=macOS,arch=arm64' ;;
  ios|ipad)
    if [ "$platform" = ios ]; then model="$IOS_DEVICE"; else model="$IPAD_DEVICE"; fi
    device="$(sim_udid "$model")"
    destination="platform=iOS Simulator,id=$device"; app="$DERIVED/Build/Products/$configuration-iphonesimulator/CuePad.app" ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac

# 这里的 Mac 构建在包里声明成 UIElement：谁起的（测试宿主、截图、测量、会话自己写的脚本）、怎么结束的，都不进程序坞、不占菜单栏。
# 写在包里而不按启动时的环境切换：脚本直接起的实例不带那些环境变量，进了程序坞的图标退出后又可能撤不掉。
# （程序坞里成堆的 CuePad 图标另有来源：挂在正式版底下的 Agent 跑的工具，见 CuePadKit 的 ChildProcess 头注释）
# 人用 Xcode ⌘R 起的不经这里，照常进程序坞；正式版由 release-mac.sh 构建
if [ "$platform" = mac ]; then build_settings+=(INFOPLIST_KEY_LSUIElement=YES); fi
# CUEPAD_SIGN=development：ad-hoc 构建完只给主程序换签名（嵌入描述文件、带 iCloud 权限并写定开发环境）。不在 xcodebuild 里换：
# 签名设置覆盖到每个 target，框架与命令行工具会要团队、bundle id；内嵌的仍是 ad-hoc，没开 Hardened Runtime 就照常加载。
sign_development() {
  [ "${CUEPAD_SIGN:-}" = development ] || return 0
  [ "$platform" = mac ] || { echo "CUEPAD_SIGN=development 只用于 mac" >&2; exit 2; }
  signing_begin
  python3 "$APPLE_DIR/scripts/provision.py" unlock
  local profile entitlements="$DERIVED/CuePad-macOS-development.entitlements" decoded="$DERIVED/profile.plist"
  # if 而不是 &&：最后一个描述文件不是它时循环以非零结束，pipefail 下整个赋值失败、set -e 一声不吭地退出
  profile="$(for f in "$PROFILES_DIR"/*.provisionprofile; do
    if security cms -D -i "$f" > "$decoded" 2>/dev/null && [ "$(plutil -extract Name raw "$decoded")" = "CuePad macOS Development" ]; then echo "$f"; fi; done | head -1)"
  [ -n "$profile" ] || { echo "没有「CuePad macOS Development」描述文件：先 provision.py profiles" >&2; exit 1; }
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  sed "s/\$(CUEPAD_APP_ID)/$CUEPAD_APP_ID/g" "$APPLE_DIR/App/Config/CuePad-macOS.entitlements" > "$entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Development" \
    -c "Add :com.apple.application-identifier string $CUEPAD_TEAM_ID.$CUEPAD_APP_ID" -c "Add :com.apple.developer.team-identifier string $CUEPAD_TEAM_ID" "$entitlements"
  # 证书只认专用钥匙串里那份（描述文件按它建）；登录钥匙串里可能有同名的另一张
  codesign --force --keychain "$HOME/.appstoreconnect/cuepad-signing.keychain-db" --sign "Apple Development" --entitlements "$entitlements" "$app"
  signing_end
}

case "$cmd" in
  check)
    "$APPLE_DIR/scripts/lint.sh"
    # Kit 的 macOS 构建（CuePi、命令行工具只在这里编到）与 iOS 编译产物目录不同，并行跑
    kit_build & kit=$!
    # 归档（Release）是整模块编译，Debug 是按文件分批的增量编译：同一份源码，有些诊断（如 nonisolated 类型里静态存非 Sendable 值）只有整模块才报，
    # 整模块编译与优化档位无关（-Onone 同样报），所以 Mac App 用 Debug 加整模块编一遍（不签名）。Mac 独有的代码也只在这里编到，连测试目标（iOS 那份编不到 #if os(macOS) 的测试，它们的警告只在这里报）。产物与 Debug 增量构建分开，免得交替时互相作废
    (
      platform=mac; DERIVED="$APPLE_DIR/.derived-wmo"; destination='platform=macOS,arch=arm64'; app="$DERIVED/Build/Products/Debug/CuePad.app"
      build_settings=(SWIFT_COMPILATION_MODE=wholemodule CODE_SIGNING_ALLOWED=NO)
      mkdir -p "$DERIVED"; built "$DERIVED/build-key" "$app" all xcb -quiet build-for-testing
    ) & wmo=$!
    status=0
    if xcd all; then python3 "$APPLE_DIR/scripts/strings.py" check || status=$?; else status=$?; fi
    wait "$kit" || status=$?
    wait "$wmo" || status=$?
    # shellcheck disable=SC2031 # 读外层的 iOS 产物目录：整模块那一段在子 shell 里换了 DERIVED 与 platform
    no_warnings "$DERIVED/warnings-$platform" || status=1
    exit $status ;;
  activity-log)
    xcd all
    signing_begin  # 脚本随它结束，锁一起放
    python3 "$APPLE_DIR/scripts/activity-log.py" "$app" "${2:-$DERIVED/activity-diagnostics.json}" ;;
  build) xcd all; sign_development ;;
  build-perf) built "$DERIVED/build-key-$platform" "$app" all xcb -quiet build ;;
  test) xc_test "$@" ;;
  shot|rec|run)
    # 截图前先查台前调度：开着就拍不对，不白等一次构建
    if [ "$platform" = mac ]; then python3 "$APPLE_DIR/scripts/app.py" preflight; fi
    xcd app
    target=()
    if [ "$platform" != mac ]; then phase 开机 sim_boot "$device"; target=(--device "$device"); fi
    library="${CUEPAD_SHOT_LIBRARY:-$APPLE_DIR/.derived/library$([ "$platform" = mac ] || echo "-$platform")}"
    exec python3 "$APPLE_DIR/scripts/app.py" "$cmd" "$platform" "$app" "$library" ${target[@]+"${target[@]}"} "${@:3}" ;;
  perf)
    # 构建与测量各自按普通任务进锁；帧与回合时长随机器忙闲变，看结束时的负载，前后对比以指令数为准
    # xcodebuild 的标准输出与错误已在 xcb 里并成一路写进 build.log；排队、用时、入口的报错走终端的标准错误，不进日志
    status=0
    "$0" build-perf "$platform" >"$DERIVED/build.log" || status=$?
    if [ "$status" != 0 ]; then
      {
        echo "perf 的构建失败（退出码 ${status}；75 是排队超时，124 是任务超时，其余多半是 xcodebuild 的）。完整输出在 $DERIVED/build.log；排队与入口的报错在上面的终端输出里，不在日志里。"
        echo "日志里的 error 行（最多 10 条，早先的错误常在末尾之前）："; grep -a 'error:' "$DERIVED/build.log" | head -10 || true
        echo "日志末尾 30 行（只是末尾，不是全部）："; tail -30 "$DERIVED/build.log"
      } >&2
      exit "$status"
    fi
    xc_enter "$([ "$platform" = ios ] && echo "$IOS_DEVICE")" "$APPLE_DIR/scripts/$perf_script" "$app" "${@:3}"
    exec "$APPLE_DIR/scripts/$perf_script" "$app" "${@:3}" ;;  # 已在锁里（脚本调脚本）时 xc_enter 直接返回
esac
