#!/usr/bin/env bash
# 源码约束检查：规则多是"某写法只准出现在白名单路径里"（forbid），另有调试目录的整文件门；命中就列出位置、原因与该用什么，退出 1。
# 用法：lint.sh [--staged]   默认查工作区；--staged 查暂存区里的内容（提交钩子用，结论对应实际提交）。xc.sh check 跑默认模式。
# 只扫 App 与 CuePadKit 的 Swift，// 之后的注释不算；另查落地页的色令牌与色板同值，与 Pi 桥扩展改了升没升版本（只在默认模式）。
# forbid 的规则清单在 lint_forbid.sh。每条规则的原因与替代只写在它的报错里；新规则先在一个真实违规（历史提交或临时注入）上证明会红再加。
set -euo pipefail
scripts="$(cd "$(dirname "$0")" && pwd)"
cd "$scripts/../.."
if [ "${1:-}" = --staged ]; then
  # 把暂存区（钩子里是 git 给的 GIT_INDEX_FILE，部分提交时是临时索引）的 Swift 文件取到临时目录，在那里跑同一组规则。
  # git 命令在检出根目录跑：钩子里设了 GIT_DIR，git 把当前目录当检出根
  staged="$(mktemp -d)"
  trap 'rm -rf "$staged"' EXIT
  git ls-files -z -- 'apple/App/*.swift' 'apple/CuePadKit/*.swift' landing/src/styles/base.css | git checkout-index -z --stdin --prefix="$staged/"
  cd "$staged"
fi
cd apple
command -v rg >/dev/null || { echo "lint.sh 要 ripgrep：brew install ripgrep" >&2; exit 1; }

status=0
# forbid <原因与替代> <正则（PCRE2）> [白名单路径…]；只查某几个目录的，调用前写 FORBID_IN="目录…"（默认 App 与 CuePadKit）；正则要跨行认就写 FORBID_U=1
forbid() {
  local why=$1 pattern=$2; shift 2
  local args=(--pcre2 --line-number --no-heading --type swift) path hits rc=0 roots
  [ -z "${FORBID_U:-}" ] || args+=(-U)
  read -ra roots <<<"${FORBID_IN:-App CuePadKit}"
  for path in "$@"; do args+=(--glob "!$path"); done
  # 只认 // 之前的代码；行内字符串里的 // 后面的就漏了，代价可接受
  hits="$(rg "${args[@]}" -e "^(?:(?!//).)*?$pattern" -- "${roots[@]}")" || rc=$?
  case $rc in
    0) printf '%s\n' "$hits"; printf '  → %s\n\n' "$why"; status=1 ;;
    1) ;;
    *) exit "$rc" ;;
  esac
}

source "$scripts/lint_forbid.sh"

# 长按菜单带预览要跨行认（菜单闭包在中间），单独一条多行规则
hits="$(rg -U --pcre2 --line-number --no-heading --type swift --glob '!App/Sources/UI/iOS/Components.swift' \
  -e '\.contextMenu\s*(?:\(menuItems:|\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}\s*preview:)' -- App CuePadKit)" && rc=0 || rc=$?
[ "$rc" -le 1 ] || exit "$rc"
if [ "$rc" = 0 ]; then
  printf '%s\n  → 带预览的长按菜单用 contextMenu(menu:lifting:)（iOS/Components.swift）：预览是系统另起的一层宿主、不继承环境，读 Workspace 这类对象直接 fatalError（2610152015 长按任务崩溃）\n\n' "$hits"
  status=1
fi

# 调试目录与产品同一个 target：文件不整个包在 DEBUG 里，Debug 构建与测试照过，Release 编不过或把调试代码发出去（350b9a47）。
# DebugHooks*.swift 是两种构建共用的入口，例外
for file in App/Sources/UI/Debug/*.swift; do
  case "${file##*/}" in DebugHooks*.swift) continue ;; esac
  first="$(grep -m1 -E '^[[:space:]]*#if\b' "$file" || true)"
  [[ "$first" == *DEBUG* ]] && continue
  printf '%s\n  → 调试目录的文件整个包在 #if DEBUG（可加平台条件）里，第一条 #if 就要带 DEBUG；两种构建都要的放 DebugHooks*.swift\n\n' "$file"
  status=1
done

# 间距只经 Spacing 的几档（规则在 lint_spacing.py 头注释）
python3 "$scripts/lint_spacing.py" || status=1

python3 "$scripts/lint_tokens.py" || status=1
# 环境值的类型里带闭包却比不了（规则与原因在 lint_env.py 头注释）
python3 "$scripts/lint_env.py" || status=1

# 落地页与 App 同一套颜色（规则在 lint_palette.py 头注释）
python3 "$scripts/lint_palette.py" App/AppGroup/Palette.swift ../landing/src/styles/base.css || status=1

# Pi 桥扩展改了要升版本（规则在 lint_extension.py 头注释）；比的是检出与 origin/main，提交钩子查的暂存区副本里没有 git，不查
[ "${1:-}" = --staged ] || python3 "$scripts/lint_extension.py" || status=1

# 注释里的到期或退役写法要附工单编号（规则在 lint_expiry.py 头注释）
python3 "$scripts/lint_expiry.py" || status=1

# Schema.baseVersion 不高于已发布标签的最小结构版本（规则在 lint_schema.py 头注释）；同样要 git，暂存区副本里没有
[ "${1:-}" = --staged ] || python3 "$scripts/lint_schema.py" || status=1

# 文档指向的名字还在（lint_docs.py 头注释）；要 git
[ "${1:-}" = --staged ] || python3 "$scripts/lint_docs.py" || status=1

exit $status
