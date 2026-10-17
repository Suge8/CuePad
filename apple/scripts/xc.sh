#!/usr/bin/env bash
# CuePad 的构建、测试、截图、测量、发布只走这里（Agent 绕开它直接调 xcodebuild、swift build/test、simctl 开关机，
# 或自己起停 CuePad，会被 .pi/extensions/xc-guard.ts 拦下）。
#   xc.sh check                                     提交前的门：lint.sh、CuePadKit 的 swift build、iOS 编译
#   xc.sh build <mac|ios|ipad>
#   xc.sh test <mac|ios|ipad> [xcodebuild 参数…]     如 -only-testing:CuePadTests/SuiteName；ios、ipad 不带参数时连 CuePadKit 也在模拟器上跑
#   xc.sh test kit [swift test 参数…]               CuePadKit 在 macOS 上的 swift test，如 --filter SuiteName
#   xc.sh shot <mac|ios|ipad> [图.png] [-- 启动参数…]  构建 → 起隔离实例 → 画面就绪后截窗口 → 退出
#   xc.sh rec  <mac|ios|ipad> [片.mov] [-- 启动参数…]  同上，录 CUEPAD_REC_SECONDS 秒（默认 12）；CUEPAD_REC_LAUNCH=1 从启动前开录（ios、ipad）
#   xc.sh run  <mac|ios|ipad> [-- 启动参数…]          起着给 bcu、axe 操作，打印 PID（模拟器另带 UDID）；Mac 实例 5 分钟后自己退出
#   xc.sh stop                                      结束本检出 run 起的 Mac 实例
#   xc.sh perf <mac|ios> [次数] [启动参数…]            单次交互：点击回合、指令、掉帧（perf-mac.sh、perf-ios.sh）；构建完只在测量那段独占机器
#   xc.sh perf idle <mac|ios> [次数] [秒] [启动参数…]   静置时的 CPU、指令、唤醒、能耗、内存与启动到就绪（perf-idle.sh）
#   xc.sh release <mac|ios> | device | provision    发布与签名（docs/release.md）
# 启动参数原样传给 App（如 -CuePadDemo YES -CuePadScene editor -theme dark；Debug 认的参数见 DebugScene.swift）。
# 实例的隔离、每个检出一份、一定退出见 app.py 头注释；排队与时限见 _lock.sh；模拟器池见 _sim.sh。
# CUEPAD_SHOT_LIBRARY 换隔离库目录（默认 apple/.derived/library[-ios|-ipad]，如真实库的只读副本）。
# 产物目录是本检出的 apple/.derived（perf 的 Release 构建在 apple/.derived-perf，Kit 在 CuePadKit/.build）：每个检出一份增量。
# 本机构建一律 ad-hoc 签名（不联网、不要账号）；CUEPAD_SIGN=development 只给同步测量（docs/verify.md「同步测量」）。
# 每个测试最多 TEST_TIME_LIMIT 秒（CUEPAD_TEST_TIME_LIMIT 覆盖，给真模型的评测用；Xcode 的测试时限，对 Swift Testing 与主线程死锁也生效）：超时记一条 "Time limit was exceeded"，非零退出。
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
  check|build) xc_enter plain "$0" "$@" ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
if [ "$cmd" = test ] && [ "$platform" = kit ]; then
  cd "$APPLE_DIR/CuePadKit" && exec swift test "${@:3}"
fi
[ "$cmd" != check ] || platform=ios
perf_script=""
if [ "$cmd" = perf ]; then
  # perf idle <平台> …：平台跟着传给 perf-idle.sh
  if [ "$platform" = idle ]; then perf_script=perf-idle.sh; platform="${3:-}"; else perf_script="perf-$platform.sh"; fi
  case "$platform" in mac|ios) ;; *) echo "用法：$0 perf [idle] <mac|ios> [参数…]" >&2; exit 2 ;; esac
fi

# perf 量的是 Release（带 DEBUG 条件，只为留下测量代码与调试场景）：数要和用户拿到的构建同一档优化
if [ "$cmd" = perf ] || [ -n "${CUEPAD_PERF_BUILD:-}" ]; then
  DERIVED="$APPLE_DIR/.derived-perf"; configuration=Release
  # 关掉 hardened runtime：ad-hoc 签名的进程加载不了别家团队签名的 Sparkle
  # shellcheck disable=SC2016 # $(inherited) 由 xcodebuild 展开
  build_settings=('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG' ENABLE_HARDENED_RUNTIME=NO)
else
  DERIVED="$APPLE_DIR/.derived"; configuration=Debug; build_settings=()
fi
mkdir -p "$DERIVED"
case "$platform" in
  mac) destination='platform=macOS,arch=arm64'; app="$DERIVED/Build/Products/$configuration/CuePad.app" ;;
  ios|ipad)
    if [ "$platform" = ios ]; then model="$IOS_DEVICE"; else model="$IPAD_DEVICE"; fi
    device="$(sim_udid "$model")"
    destination="platform=iOS Simulator,id=$device"; app="$DERIVED/Build/Products/$configuration-iphonesimulator/CuePad.app" ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac

# 本机 ad-hoc 签名：工程默认是团队 + 自动签名（给发布用），iCloud 这类受限能力在 ad-hoc 下无法启动，
# 所以覆盖成不带团队与身份、且用不含这些能力的 macOS 权限文件。
local_signing=(DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- CUEPAD_MAC_ENTITLEMENTS=App/Config/CuePad-macOS-local.entitlements)
# 系统 SDK 的预编译模块（约 166 个，冷编前 10 秒都在生成它们）所有检出共用一份：Xcode 默认就放在各工程共用的 DerivedData 根下，
# 这里的产物目录按检出分开，不指定就每个新检出从头编一遍。实测换检出路径照样命中，冷编约快 17%。删 .derived 不会清掉它
shared_cache="$HOME/Library/Caches/cuepad-xc"
shared_modules=(SDK_EXPLICIT_MODULES_OUTPUT_PATH="$shared_cache/SDKExplicitPrecompiledModules" MODULE_CACHE_DIR="$shared_cache/ModuleCache.noindex" SDK_STAT_CACHE_DIR="$shared_cache")

# 退出码即 xcodebuild 的退出码（pipefail）。-quiet 下只有警告的编译步骤会被打成
# "error: the following command failed with exit code 0 but produced no further output"——不是失败，滤掉这一行免得误读。
xcb() {
  xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$DERIVED" ${asc_auth[@]+"${asc_auth[@]}"} "$@" \
    "${local_signing[@]}" "${shared_modules[@]}" ${build_settings[@]+"${build_settings[@]}"} 2>&1 \
    | { grep -v 'failed with exit code 0 but produced no further output' || true; }
}

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
    xcb -quiet build || status=$?
    wait "$kit" || status=$?
    exit $status ;;
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
  shot|rec|run)
    # 截图前先查台前调度：开着就拍不对，不白等一次构建
    if [ "$platform" = mac ]; then python3 "$APPLE_DIR/scripts/app.py" preflight; fi
    xcb -quiet build
    rest=("${@:3}") target=()
    if [ "${#rest[@]}" -gt 0 ] && [ "${rest[0]}" != -- ]; then target=(--out "${rest[0]}"); rest=("${rest[@]:1}"); fi
    if [ "$platform" != mac ]; then sim_boot "$device"; target+=(--device "$device"); fi
    library="${CUEPAD_SHOT_LIBRARY:-$APPLE_DIR/.derived/library$([ "$platform" = mac ] || echo "-$platform")}"
    exec python3 "$APPLE_DIR/scripts/app.py" "$cmd" "$platform" "$app" "$library" ${target[@]+"${target[@]}"} ${rest[@]+"${rest[@]}"} ;;
  perf)
    # 构建照普通任务排队；独占机器只给交互测量那一段（帧与主线程时间怕别的进程抢），其间别的检出的构建、截图才等它。
    # 静置开销读的是进程自己的内核记账（指令、CPU 时间、唤醒），不随机器忙闲变，不独占
    CUEPAD_PERF_BUILD=1 "$0" build "$platform" >"$DERIVED/build.log" || { tail -30 "$DERIVED/build.log" >&2; exit 1; }
    mode=exclusive
    if [ "$perf_script" = perf-idle.sh ]; then if [ "$platform" = ios ]; then mode=sim; else mode=plain; fi; fi
    xc_enter "$mode" "$APPLE_DIR/scripts/$perf_script" "$app" "${@:3}"
    exec "$APPLE_DIR/scripts/$perf_script" "$app" "${@:3}" ;;  # 已在锁里（脚本调脚本）时 xc_enter 直接返回
esac
