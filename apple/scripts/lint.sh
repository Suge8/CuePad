#!/usr/bin/env bash
# 源码约束检查：每条规则是"某写法只准出现在白名单路径里"，命中就列出位置、原因与该用什么，退出 1。
# 用法：lint.sh [--staged]   默认查工作区；--staged 查暂存区里的内容（提交钩子用，结论对应实际提交）。xc.sh check 跑默认模式。
# 只扫 App 与 CuePadKit 的 Swift，// 之后的注释不算。
# 每条规则的原因与替代只写在它的报错里；新规则先在一个真实违规（历史提交或临时注入）上证明会红再加。
set -euo pipefail
cd "$(dirname "$0")/../.."
if [ "${1:-}" = --staged ]; then
  # 把暂存区（钩子里是 git 给的 GIT_INDEX_FILE，部分提交时是临时索引）的 Swift 文件取到临时目录，在那里跑同一组规则。
  # git 命令在检出根目录跑：钩子里设了 GIT_DIR，git 把当前目录当检出根
  staged="$(mktemp -d)"
  trap 'rm -rf "$staged"' EXIT
  git ls-files -z -- 'apple/App/*.swift' 'apple/CuePadKit/*.swift' | git checkout-index -z --stdin --prefix="$staged/"
  cd "$staged"
fi
cd apple

status=0
# forbid <原因与替代> <正则（PCRE2）> [白名单路径…]
forbid() {
  local why=$1 pattern=$2; shift 2
  local args=(--pcre2 --line-number --no-heading --type swift) path hits rc=0
  for path in "$@"; do args+=(--glob "!$path"); done
  # 只认 // 之前的代码；行内字符串里的 // 后面的就漏了，代价可接受
  hits="$(rg "${args[@]}" -e "^(?:(?!//).)*?$pattern" -- App CuePadKit)" || rc=$?
  case $rc in
    0) printf '%s\n' "$hits"; printf '  → %s\n\n' "$why"; status=1 ;;
    1) ;;
    *) exit "$rc" ;;
  esac
}

forbid "等待的转圈用 Spinner（LoopLayer.swift）：全 App 的转圈同一个样子、同一个颜色，交给渲染服务转、App 进程不参与" \
  '\bProgressView\b'
forbid "空态与出错页用 EmptyState，不用系统 ContentUnavailableView：全 App 空态统一成吉祥物加一句现状，品牌一致（a2e5df76）" \
  '\bContentUnavailableView\b'
# 唯一例外：启动失败时还没有窗口能挂 dialog
forbid "Mac 上的确认框用 dialog、浮层用 panel、选文件用 FilePicker（非模态 begin）：runModal 与 NSAlert 把主线程关在嵌套事件循环里，sheet 开关各约 300ms" \
  '\b(runModal|NSAlert)\b' 'App/Sources/macOS/AppDelegate.swift'
forbid "常驻循环动效只用 LoopLayer（Core Animation）：SwiftUI 的 repeatForever 与符号动效每帧在 App 进程里重算，静止的 Agent 页也占约 9% CPU（随值触发一次的 .nonRepeating 不常驻，不算）" \
  '(\brepeatForever\b|(?<!\()\.symbolEffect\((?![^)]*\.nonRepeating\b))' '**/LoopLayer.swift'
forbid "不用 DispatchQueue.main.asyncAfter：它取消不了。等事件用通知序列或 NextFrame，真要定时用可取消的 Task.sleep" \
  'DispatchQueue\.main\.asyncAfter'
forbid "不访问 NSTextView/UITextView 的 layoutManager：访问一次就把视图永久降级到 TextKit 1，用 textLayoutManager" \
  '\.layoutManager\b'
forbid "自绘玻璃只经 glass(in:)（Surfaces.swift）：材质统一 .regular，降低透明度、增强对比度时退回实底" \
  '\.glassEffect\(' '**/Theme/Surfaces.swift'
forbid "产品代码不写 #if DEBUG，经 DebugHooks 碰调试画面：两种构建的分叉收在 DebugHooks 一处（Release 里钩子什么都不做）；调试代码放 App/Sources/UI/Debug，演示数据在 Seed.swift" \
  '^\s*#(?:if|elseif)\b.*\bDEBUG\b' 'App/Sources/UI/Debug/**' '**/CueStore/Seed.swift'

exit $status
