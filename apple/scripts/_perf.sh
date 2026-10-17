# shellcheck shell=bash
# 被 perf-mac.sh、perf-ios.sh、perf-idle.sh source：测量用的构建与 Mac 实例启动只在这里一份。
# 构建是 Release 带 DEBUG 条件（只为留下测量代码）：Mac 产物在 apple/.derived-perf-release（Instruments 也用这份），iOS 在 apple/.derived-perf-ios。
# shellcheck disable=SC2034 # 由 source 它的脚本使用
PERF_MAC_DERIVED="$APPLE_DIR/.derived-perf-release"
PERF_IOS_DERIVED="$APPLE_DIR/.derived-perf-ios"
PERF_MAC_EXE="$PERF_MAC_DERIVED/Build/Products/Release/CuePad.app/Contents/MacOS/CuePad"
PERF_IOS_APP="$PERF_IOS_DERIVED/Build/Products/Release-iphonesimulator/CuePad.app"

# perf_build mac | perf_build ios <模拟器 UDID>
# 本机 ad-hoc 签名；Mac 关掉 hardened runtime，否则 ad-hoc 签名的进程加载不了别家团队签名的 Sparkle
perf_build() {
  local derived destination extra=()
  if [ "$1" = mac ]; then
    derived="$PERF_MAC_DERIVED" destination='platform=macOS,arch=arm64'
    extra=(CUEPAD_MAC_ENTITLEMENTS=App/Config/CuePad-macOS-local.entitlements ENABLE_HARDENED_RUNTIME=NO)
  else
    derived="$PERF_IOS_DERIVED" destination="platform=iOS Simulator,id=$2"
  fi
  mkdir -p "$derived"
  # shellcheck disable=SC2016 # $(inherited) 由 xcodebuild 展开
  xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration Release \
    -destination "$destination" -derivedDataPath "$derived" -quiet build \
    DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG' "${extra[@]}" \
    >"$derived/build.log" 2>&1 || { tail -30 "$derived/build.log" >&2; exit 1; }
}

# perf_launch_mac <库目录> [启动参数…]：前台进程里 exec 测量构建（在后台调用时 $! 就是 CuePad 本身，结束它不会留下进程）。
# 库与 Agent 目录隔离；同一时间只留一个 Mac 调试实例：先结束 xc.sh run/shot 记下的那个（只认产物目录里的 CuePad）。
perf_launch_mac() {
  local library="$1" pidfile
  shift
  pidfile="/tmp/cuepad-shot-$(id -u)/mac.pid"
  if [ -f "$pidfile" ] && [[ "$(ps -o comm= -p "$(cat "$pidfile")" 2>/dev/null)" == */.derived/Build/Products/Debug/CuePad.app/Contents/MacOS/CuePad ]]; then
    kill -TERM "$(cat "$pidfile")"
    rm -f "$pidfile"
  fi
  CUEPAD_LIBRARY_DIR="$library" PI_CODING_AGENT_DIR="$PERF_MAC_DERIVED/pi-agent" CUEPAD_PI_SOCKET_DIR="/tmp/cuepad-perf-$(id -u)" \
    exec "$PERF_MAC_EXE" "$@"
}
