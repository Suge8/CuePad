#!/usr/bin/env bash
# CuePad 的构建、测试、截图、测量、发布只走这里（Agent 绕开它直接调 xcodebuild、swift build/test、simctl 开关机，
# 或自己起停 CuePad，会被 .pi/extensions/xc-guard.ts 拦下）。
#   xc.sh check                                     提交前的门：lint.sh、CuePadKit 的 swift build、iOS 编译（连测试目标）
#   xc.sh build <mac|ios|ipad>
#   xc.sh test <mac|ios|ipad> [xcodebuild 参数…]     如 -only-testing:CuePadTests/SuiteName；ios、ipad 不带参数时连 CuePadKit 也在模拟器上跑
#   xc.sh test kit [xcodebuild 参数…]               CuePadKit 在 macOS 上的测试，如 -only-testing:CueSyncTests/PendingTests
#     test 只打印编译的警告与错误、失败的用例与汇总；完整输出（App 日志、每条用例）在 apple/.derived/test.log
#   xc.sh shot <mac|ios|ipad> [图.png] [-- 启动参数…]  构建 → 起隔离实例 → 画面就绪后截窗口 → 退出
#   xc.sh rec  <mac|ios|ipad> [片.mov] [-- 启动参数…]  同上，录 CUEPAD_REC_SECONDS 秒（默认 12）；CUEPAD_REC_LAUNCH=1 从启动前开录（ios、ipad）
#   xc.sh run  <mac|ios|ipad> [-- 启动参数…]          起着给 bcu、axe 操作，打印 PID（模拟器另带 UDID）；Mac 实例 5 分钟后自己退出
#   xc.sh stop                                      结束本检出 run 起的 Mac 实例
#   xc.sh perf <mac|ios> [次数] [启动参数…]            单次交互：点击回合、指令、掉帧（perf-mac.sh、perf-ios.sh）；只有带 -CuePadForeground YES 的 Mac 测量独占机器
#   xc.sh perf idle <mac|ios> [次数] [秒] [启动参数…]   静置时的 CPU、指令、唤醒、能耗、内存与启动到就绪（perf-idle.sh）
#   xc.sh release <mac|ios> | device | provision    发布与签名（docs/release.md）
# 启动参数原样传给 App（如 -CuePadDemo YES -CuePadScene editor -theme dark；Debug 认的参数见 DebugScene.swift）。
# 实例的隔离、每个检出一份、一定退出见 app.py 头注释；排队、在等谁、等待上限与任务时限见 _lock.sh；模拟器池见 _sim.sh。
# CUEPAD_SHOT_LIBRARY 换隔离库目录（默认 apple/.derived/library[-ios|-ipad]，如真实库的只读副本）。
# 产物目录是本检出的 apple/.derived（perf 的 Release 构建在 apple/.derived-perf，Kit 的测试在 apple/.derived/kit-<平台>，check 的 Kit 构建在 CuePadKit/.build）：每个检出一份增量。
# 本机构建一律 ad-hoc 签名（工程默认，见 Signing.xcconfig）；CUEPAD_SIGN=development 只给同步测量（docs/verify.md「同步测量」）。
# 每个测试最多 TEST_TIME_LIMIT 秒（CUEPAD_TEST_TIME_LIMIT 覆盖，给真模型的评测用；Xcode 的测试时限，对 Swift Testing 与主线程死锁也生效）：超时记一条 "Time limit was exceeded"，非零退出。
# Kit 的测试因此也走 xcodebuild：swift test（Swift 6.4）没有测试时限的参数，Swift Testing 的 .timeLimit 只取消测试任务、要等它自己结束，
# 不响应取消的等待会让整个测试进程挂到任务时限。xcodebuild 只把 TEST_RUNNER_ 开头的环境变量交给测试进程（去掉前缀），测试进程的工作目录是 /private/tmp。
# 提交钩子：git config core.hooksPath apple/scripts/hooks（每个仓库一次）。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
# shellcheck source=_sim.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_sim.sh"
# shellcheck source=_lock.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_lock.sh"
IOS_DEVICE="${CUEPAD_IOS_DEVICE:-iPhone 17}"
IPAD_DEVICE="${CUEPAD_IPAD_DEVICE:-iPad Pro 11-inch (M5)}"
# 正常的测试几秒内跑完，最慢的也不到一分钟；挂住的测试曾让测试宿主停了 34 分钟没人发现
TEST_TIME_LIMIT=${CUEPAD_TEST_TIME_LIMIT:-120}
USAGE="用法：$0 <check|build|test|shot|rec|run|stop|perf|release|device|provision> [mac|ios|ipad|kit] …（见脚本头注释）"

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
  stop) exec python3 "$APPLE_DIR/scripts/app.py" stop ;;
  perf) ;;  # 先构建、再测量，两段各自进锁（见下）
  test|shot|rec|run) case "$platform" in ios|ipad) xc_enter sim "$0" "$@" ;; *) xc_enter plain "$0" "$@" ;; esac ;;
  check|build|build-perf) xc_enter plain "$0" "$@" ;;  # build-perf：perf 的构建段，内部用
  *) echo "$USAGE" >&2; exit 2 ;;
esac
[ "$cmd" != check ] || platform=ios
perf_script=""
if [ "$cmd" = perf ]; then
  # perf idle <平台> …：平台跟着传给 perf-idle.sh
  if [ "$platform" = idle ]; then perf_script=perf-idle.sh; platform="${3:-}"; else perf_script="perf-$platform.sh"; fi
  case "$platform" in mac|ios) ;; *) echo "用法：$0 perf [idle] <mac|ios> [参数…]" >&2; exit 2 ;; esac
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
# 写在包里而不按启动时的环境切换：脚本直接起的实例不带那些环境变量，进了程序坞的图标退出后又可能撤不掉（曾攒下上百个）。
# 人用 Xcode ⌘R 起的不经这里，照常进程序坞；正式版由 release-mac.sh 构建
if [ "$platform" = mac ]; then build_settings+=(INFOPLIST_KEY_LSUIElement=YES); fi
# 系统 SDK 的预编译模块（约 166 个，冷编前 10 秒都在生成它们）所有检出共用一份：Xcode 默认就放在各工程共用的 DerivedData 根下，
# 这里的产物目录按检出分开，不指定就每个新检出从头编一遍。实测换检出路径照样命中，冷编约快 17%。删 .derived 不会清掉它
shared_cache="$HOME/Library/Caches/cuepad-xc"
shared_modules=(SDK_EXPLICIT_MODULES_OUTPUT_PATH="$shared_cache/SDKExplicitPrecompiledModules" MODULE_CACHE_DIR="$shared_cache/ModuleCache.noindex" SDK_STAT_CACHE_DIR="$shared_cache")

# 退出码即 xcodebuild 的退出码（pipefail）。-quiet 下只有警告的编译步骤会被打成
# "error: the following command failed with exit code 0 but produced no further output"——不是失败，滤掉这一行免得误读。
xcb() {
  xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$DERIVED" "$@" \
    "${shared_modules[@]}" ${build_settings[@]+"${build_settings[@]}"} 2>&1 \
    | { grep -v 'failed with exit code 0 but produced no further output' || true; }
}

# Debug 一律连测试目标一起编（build-for-testing），与 test 同一张构建图：测试目标也链接 CuePadKit 时，Xcode 把被几个目标共用的
# 包产品改编成动态框架，只编 App 时却静态链接。两种编法交替时，一边留下的旧模块会被另一边的 App 编译读到（报"没有这个成员"、
# 改了存储属性后一启动就崩在 Kit 的释放里），每次切换还要重新链接、签名。测量用的 Release（build-perf）不编测试，不受影响
xcd() { xcb -quiet build-for-testing "$@"; }

# CUEPAD_SIGN=development：ad-hoc 构建完只给主程序换签名（嵌入描述文件、带 iCloud 权限并写定开发环境）。不在 xcodebuild 里换：
# 签名设置覆盖到每个 target，框架与命令行工具会要团队、bundle id；内嵌的仍是 ad-hoc，没开 Hardened Runtime 就照常加载。
sign_development() {
  [ "${CUEPAD_SIGN:-}" = development ] || return 0
  [ "$platform" = mac ] || { echo "CUEPAD_SIGN=development 只用于 mac" >&2; exit 2; }
  python3 "$APPLE_DIR/scripts/provision.py" unlock
  local profile entitlements="$DERIVED/CuePad-macOS-development.entitlements" decoded="$DERIVED/profile.plist"
  # if 而不是 &&：最后一个描述文件不是它时循环以非零结束，pipefail 下整个赋值失败、set -e 一声不吭地退出
  profile="$(for f in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"/*.provisionprofile; do
    if security cms -D -i "$f" > "$decoded" 2>/dev/null && [ "$(plutil -extract Name raw "$decoded")" = "CuePad macOS Development" ]; then echo "$f"; fi; done | head -1)"
  [ -n "$profile" ] || { echo "没有「CuePad macOS Development」描述文件：先 provision.py profiles" >&2; exit 1; }
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  cp "$APPLE_DIR/App/Config/CuePad-macOS.entitlements" "$entitlements"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-container-environment string Development" \
    -c "Add :com.apple.application-identifier string $CUEPAD_TEAM_ID.com.sugeh.cuepad" -c "Add :com.apple.developer.team-identifier string $CUEPAD_TEAM_ID" "$entitlements"
  # 证书只认专用钥匙串里那份（描述文件按它建）；登录钥匙串里可能有同名的另一张
  codesign --force --keychain "$HOME/.appstoreconnect/cuepad-signing.keychain-db" --sign "Apple Development" --entitlements "$entitlements" "$app"
}

case "$cmd" in
  check)
    "$APPLE_DIR/scripts/lint.sh"
    # Kit 的 macOS 构建（CuePi、命令行工具只在这里编到）与 iOS 编译产物目录不同，并行跑
    (cd "$APPLE_DIR/CuePadKit" && swift build --quiet) & kit=$!
    status=0
    xcd || status=$?
    wait "$kit" || status=$?
    exit $status ;;
  build) xcd; sign_development ;;
  build-perf) xcb -quiet build ;;
  test)
    limits=(-test-timeouts-enabled YES -maximum-test-execution-time-allowance "$TEST_TIME_LIMIT")
    # 先开好领到的模拟器（停用 PosterBoard，见 _sim.sh），xcodebuild 就用开着的这台。
    # 再卸掉上一次装的 App：它开着的实时活动在重装时被系统结束，系统随即把 App 叫到后台（不带测试的环境），
    # 正撞上测试宿主的启动，测试进程就连不上（"The test runner hung before establishing connection"）。卸掉时活动一起没了，没有这一下
    if [ -n "${device:-}" ]; then sim_boot "$device"; xcrun simctl uninstall "$device" com.sugeh.cuepad; fi
    # 屏幕上只留编译的警告与错误、失败的用例（带原因）与汇总：编译的每一步、App 与测试宿主的日志、每条用例的开始与通过一次就是几千行，
    # 会把失败挤出 Agent 的输出上限。所以先 -quiet 编（只出警告与错误），再不带 -quiet 跑（-quiet 连失败的原因也吞掉），跑的输出滤掉上面那些；
    # 完整输出写进 log，查失败前后的日志去那里
    log="$DERIVED/test.log"; : >"$log"
    zwsp="$(printf '\342\200\213')"  # Swift Testing 在部分行首加零宽空格
    noise="^($zwsp)*(◇ |✔ Suite .* passed after|✔ Test ([^ (]+\\(|\").* passed after)|^Test (Case|Suite) .* (started|passed)"  # 留着「✔ Test run with」那行汇总
    noise+='|^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+[+-][0-9]{4} [^ ]+\[[0-9]+:[0-9a-f]+\] |DVTAssertions|^(Details|Object|Method|Thread): |^Please file a bug|^\{ platform:|^--- xcodebuild: WARNING: Using the first'
    shown() { tee -a "$log" | { grep -avE "$noise" || true; }; }
    # 编译只认收窄参数（只编要跑的测试目标）；-test-iterations 这类只给跑的那一步
    narrowed() { local a; for a in "$@"; do case "$a" in -only-testing:*|-skip-testing:*) printf '%s\0' "$a" ;; esac; done; }
    kit_test() {
      local narrow=(); while IFS= read -r -d '' a; do narrow+=("$a"); done < <(narrowed "$@")
      (cd "$APPLE_DIR/CuePadKit" && xcodebuild -quiet build-for-testing -scheme CuePadKit-Package -destination "$destination" -derivedDataPath "$DERIVED/kit-$platform" ${narrow[@]+"${narrow[@]}"} 2>&1 \
        && xcodebuild test-without-building -scheme CuePadKit-Package -destination "$destination" -derivedDataPath "$DERIVED/kit-$platform" "${limits[@]}" "$@" 2>&1) \
        | { grep -v 'failed with exit code 0 but produced no further output' || true; }
    }
    # iOS/iPad：同一个入口也在模拟器上跑 CuePadKit 的测试（iOS 编辑器等只在这里跑；macOS 上的 Kit 测试是 test kit）。
    # 带了收窄参数（-only-testing 等）时只跑 App 那部分；两部分都跑完再按其一失败退出。
    status=0
    if [ "$platform" = kit ]; then
      kit_test "${@:3}" | shown || status=$?
    else
      narrow=(); while IFS= read -r -d '' a; do narrow+=("$a"); done < <(narrowed "${@:3}")
      { xcd ${narrow[@]+"${narrow[@]}"} && xcb test-without-building "${limits[@]}" "${@:3}"; } | shown || status=$?
      if [ "$platform" != mac ] && [ "$#" -le 2 ]; then kit_test | shown || status=$?; fi
    fi
    # 点名的测试一个也没对上（名字或所在的 Suite 写错）时 xcodebuild 照样报成功
    if [[ " ${*:3}" == *" -only-testing:"* ]] && ! grep -aqE 'Test run with [1-9]|Executed [1-9][0-9]* tests?,' "$log"; then
      echo "-only-testing 一个测试也没对上：Swift Testing 写 <测试目标>/<Suite 类型名>/<函数名>()，用例所在的类型以源码为准" >&2
      status=1
    fi
    echo "完整输出（含 App 日志）：$log"
    exit $status ;;
  shot|rec|run)
    # 截图前先查台前调度：开着就拍不对，不白等一次构建
    if [ "$platform" = mac ]; then python3 "$APPLE_DIR/scripts/app.py" preflight; fi
    xcd
    rest=("${@:3}") target=()
    if [ "${#rest[@]}" -gt 0 ] && [ "${rest[0]}" != -- ]; then target=(--out "${rest[0]}"); rest=("${rest[@]:1}"); fi
    if [ "$platform" != mac ]; then sim_boot "$device"; target+=(--device "$device"); fi
    library="${CUEPAD_SHOT_LIBRARY:-$APPLE_DIR/.derived/library$([ "$platform" = mac ] || echo "-$platform")}"
    exec python3 "$APPLE_DIR/scripts/app.py" "$cmd" "$platform" "$app" "$library" ${target[@]+"${target[@]}"} ${rest[@]+"${rest[@]}"} ;;
  perf)
    # 构建照普通任务排队；测量只有前台和预算比的 Mac 一种独占（帧与回合时长怕别的进程抢），其余只比指令数，不随机器忙闲变
    "$0" build-perf "$platform" >"$DERIVED/build.log" || { tail -30 "$DERIVED/build.log" >&2; exit 1; }
    mode=plain
    if [ "$platform" = ios ]; then mode=sim
    elif [ "$perf_script" = perf-mac.sh ] && [[ " ${*:3} " == *" -CuePadForeground YES "* ]]; then mode=exclusive; fi
    xc_enter "$mode" "$APPLE_DIR/scripts/$perf_script" "$app" "${@:3}"
    exec "$APPLE_DIR/scripts/$perf_script" "$app" "${@:3}" ;;  # 已在锁里（脚本调脚本）时 xc_enter 直接返回
esac
