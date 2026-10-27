# shellcheck shell=bash
# 被 xc.sh source：怎么调 xcodebuild（xcb、xcd），与构建前判断这份源码是不是已经编过（built），编过就跳过 xcodebuild。
# 用到 xc.sh 的 APPLE_DIR、DERIVED、platform、configuration、destination、app、build_settings（调用时才读）。
#
# 源码没变就跳过：代码没动时空编也要 3–133 秒（随负载）。指纹 = HEAD + 相对 HEAD 的改动内容 + 未跟踪文件的内容 + 平台、配置、构建设置、
# CUEPAD_SIGN + Xcode 的版本号（换 Xcode 即换 SDK）。工程文件、Package.resolved、xcconfig、CuePadKit 都在 apple/ 里，一并算；
# apple/ 之外没有构建的输入，scripts/ 里没有（工程里没有脚本阶段，xc.sh 给的设置已算进去）。
# 指纹文件第一行是指纹，其后每行是这份源码已编过的范围：all（整套测试目标）或一组收窄参数（-only-testing 只编那几个）。
# 要的范围编过、或已编过 all 就跳过；shot、run 只要 App，编过任何范围都行。换了源码从头记。
# 指纹在构建成功后才记、构建前先删（被打断的构建留不下旧指纹），产物不在也不跳。构建中途改了源码不会误跳：指纹取在构建前。
build_key() {
  {
    git -C "$APPLE_DIR" rev-parse HEAD
    git -C "$APPLE_DIR" diff HEAD --binary -- . ':(exclude)scripts'
    (cd "$APPLE_DIR" && git ls-files -o --exclude-standard -z -- . ':(exclude)scripts' | xargs -0 shasum -a 1)
    plutil -extract ProductBuildVersion raw "${DEVELOPER_DIR:-$(xcode-select -p)}/../version.plist"
    printf '%s\n' "$platform" "$configuration" "${CUEPAD_SIGN:-}" ${build_settings[@]+"${build_settings[@]}"}
  } | shasum -a 1
}
# built <指纹文件> <产物> <范围：app|all|收窄参数> <构建命令…>：这份源码编过所要的范围且产物在就跳过，否则构建并记下
built() {
  local keyfile="$1" product="$2" need="$3" key covered=""; shift 3
  key="$(build_key)"
  [ "$(head -1 "$keyfile" 2>/dev/null)" != "$key" ] || covered="$(tail -n +2 "$keyfile")"
  if [ -e "$product" ] && [ -n "$covered" ] && { [ "$need" = app ] || grep -qxF -e all -e "$need" <<<"$covered"; }; then return 0; fi
  rm -f "$keyfile"
  phase 编译 "$@" || return
  [ "$need" != app ] || need=all
  { printf '%s\n' "$key"; [ -z "$covered" ] || printf '%s\n' "$covered"; printf '%s\n' "$need"; } >"$keyfile"
}

# 系统 SDK 的预编译模块（约 166 个，冷编前 10 秒都在生成它们）所有检出共用一份：Xcode 默认就放在各工程共用的 DerivedData 根下，
# 这里的产物目录按检出分开，不指定就每个新检出从头编一遍。实测换检出路径照样命中，冷编约快 17%。删 .derived 不会清掉它
shared_cache="$HOME/Library/Caches/cuepad-xc"
shared_modules=(SDK_EXPLICIT_MODULES_OUTPUT_PATH="$shared_cache/SDKExplicitPrecompiledModules" MODULE_CACHE_DIR="$shared_cache/ModuleCache.noindex" SDK_STAT_CACHE_DIR="$shared_cache")
# 包产品被 App 与测试目标共用而改编成动态框架时（见 xcd 的注释），Xcode 按改编前的静态目标对账依赖，
# 每次都报 "'CueStore' is missing a dependency on 'CueText'"：动态的 CueStore 实际链着 CueText.framework，是误报。
# 目标之间的依赖都写在工程与包的声明里，真缺依赖会在编译时报"找不到模块"，所以整个关掉这项诊断。
quiet_diagnostics=(DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO)

# 退出码即 xcodebuild 的退出码（pipefail）。-quiet 下只有警告的编译步骤会被打成
# "error: the following command failed with exit code 0 but produced no further output"——不是失败，滤掉这一行免得误读。
xcb() {
  xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration "$configuration" \
    -destination "$destination" -derivedDataPath "$DERIVED" "$@" \
    "${shared_modules[@]}" "${quiet_diagnostics[@]}" ${build_settings[@]+"${build_settings[@]}"} 2>&1 \
    | { grep -v 'failed with exit code 0 but produced no further output' || true; }
}

# Debug 一律连测试目标一起编（build-for-testing），与 test 同一张构建图：测试目标也链接 CuePadKit 时，Xcode 把被几个目标共用的
# 包产品改编成动态框架，只编 App 时却静态链接。两种编法交替时，一边留下的旧模块会被另一边的 App 编译读到（报"没有这个成员"、
# 改了存储属性后一启动就崩在 Kit 的释放里），每次切换还要重新链接、签名。测量用的 Release（build-perf）不编测试，不受影响
# 第一个参数是范围（见 _build.sh 的 built），其余收窄参数原样给 xcodebuild
xcd() { local need="$1"; shift; built "$DERIVED/build-key-$platform" "$app" "$need" xcb -quiet build-for-testing "$@"; }
