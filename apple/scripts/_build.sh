# shellcheck shell=bash
# 被 xc.sh source：构建前判断这份源码是不是已经编过（built），编过就跳过 xcodebuild。用到 xc.sh 的 APPLE_DIR、platform、configuration、build_settings。
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
