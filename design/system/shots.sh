#!/usr/bin/env bash
# 设计系统迁移的截图验收：按名字重拍基线里的几张（名字与参数只在下面这张表），每个平台一次 xc.sh shot（一次构建、一次进锁）。
# 基线在 apple/.derived/polish-system/（proto/polish-system 98c0ad8f7 拍的），重拍的出到 $OUT（默认它下面的 after/），同名逐张对看。
# 用法：design/system/shots.sh [名…]      不给名字拍全部；OUT=目录 改输出（换基线：OUT=apple/.derived/polish-system）
set -eo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
out="${OUT:-$root/apple/.derived/polish-system/after}"
d="-CuePadDemo YES"
w="-CuePadWindowSize 1512x945 -theme light"

table() {
  cat <<EOF
mac-board           $d -CuePadScene progress $w
mac-board-dark      $d -CuePadScene progress -CuePadWindowSize 1512x945 -theme dark
mac-session         $d -CuePadScene session -CuePadSession homepage $w
mac-cardpicker      $d -CuePadScene session -CuePadSession scratch -CuePadComposer cards $w
mac-project         $d -CuePadProject CuePad $w
mac-shelf           $d -CuePadScene shelf $w
mac-task            $d -CuePadScene task -CuePadProject CuePad $w
mac-search          $d -CuePadScene search -CuePadSearch 落地 $w
mac-library         $d -CuePadScene library $w
mac-trash           $d -CuePadScene trash $w
mac-cuememory       $d -CuePadScene cuememory $w
mac-cuerun          $d -CuePadScene cuerun $w
mac-editor          $d -CuePadScene editor $w
mac-projectform     $d -CuePadScene projectform $w
mac-select          $d -CuePadScene select -CuePadProject CuePad $w
mac-unreadable      -CuePadCatalogFailure YES $w
mac-agentsetup      $d -CuePadScene agentsetup -theme light
mac-settings        $d -CuePadScene settings -theme light
mac-settings-agents $d -CuePadScene settings -CuePadSettingsPane agents -theme light
mac-menubar         $d -CuePadScene menubar -theme light
mac-cuebar          $d -CuePadScene cuebar -theme light
ios-cue             $d -CuePadScene cue
ios-cue-dark        $d -CuePadScene cue -theme dark
ios-cuepanel        $d -CuePadScene cue -CuePadCuePanel YES
ios-sidebar         $d -CuePadScene sidebar
ios-project         $d -CuePadScene project -CuePadProject CuePad
ios-progress        $d -CuePadScene progress
ios-sessions        $d -CuePadScene sessions
ios-panel-rows      $d -CuePadScene cue -CuePadCuePanel YES -theme dark
ios-quota           $d -CuePadScene progress -CuePadQuotaOpen YES
ios-session         $d -CuePadScene session
ios-session-dark    $d -CuePadScene session -theme dark
ios-cardpicker      $d -CuePadScene session -CuePadSession scratch -CuePadComposer cards
ios-newsession      $d -CuePadScene newsession
ios-task            $d -CuePadScene task -CuePadProject CuePad
ios-settings        $d -CuePadScene settings
ios-search          $d -CuePadScene search -CuePadSearch 落地
ios-library         $d -CuePadScene library
ios-trash           $d -CuePadScene trash
ios-cuememory       $d -CuePadScene cuememory
ios-editor          $d -CuePadScene editor
ios-projectform     $d -CuePadScene projectform -CuePadProject CuePad
ios-style           $d -CuePadScene style
ios-unreadable      -CuePadCatalogFailure YES
ipad-progress       $d -CuePadScene progress
ipad-session        $d -CuePadScene session
ipad-settings       $d -CuePadScene settings
EOF
}

args_of() { table | awk -v n="$1" '$1 == n { $1 = ""; print substr($0, 2) }'; }

names=("$@")
[ ${#names[@]} -gt 0 ] || while read -r name _; do names+=("$name"); done < <(table)
for name in "${names[@]}"; do
  [ -n "$(args_of "$name")" ] || { echo "表里没有：$name" >&2; exit 2; }
done
mkdir -p "$out"
out="$(cd "$out" && pwd)"
status=0
for platform in mac ios ipad; do
  batch=()
  for name in "${names[@]}"; do
    [ "${name%%-*}" = "$platform" ] || continue
    [ ${#batch[@]} -eq 0 ] || batch+=(",")
    read -r -a launch <<< "$(args_of "$name")"
    batch+=("$out/$name.png" -- "${launch[@]}")
  done
  [ ${#batch[@]} -eq 0 ] || "$root/apple/scripts/xc.sh" shot "$platform" "${batch[@]}" || status=$?
done
exit $status
