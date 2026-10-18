#!/usr/bin/env bash
# 源码约束检查：规则多是"某写法只准出现在白名单路径里"（forbid），另有调试目录的整文件门；命中就列出位置、原因与该用什么，退出 1。
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
forbid "按时刻换字的文字用 LiveText（Moments.swift，不用系统时间文本的原因在它的注释里）" \
  '\.currentDate\b'
forbid "不用 DispatchQueue.main.asyncAfter：它取消不了。等事件用通知序列或 NextFrame，真要定时用可取消的 Task.sleep" \
  'DispatchQueue\.main\.asyncAfter'
forbid "不访问 NSTextView/UITextView 的 layoutManager：访问一次就把视图永久降级到 TextKit 1，用 textLayoutManager" \
  '\.layoutManager\b'
forbid "自绘玻璃只经 glass(in:)（Surfaces.swift）：材质统一 .regular，降低透明度、增强对比度时退回实底" \
  '\.glassEffect\(' '**/Theme/Surfaces.swift'
forbid "产品代码不写 #if DEBUG，经 DebugHooks 碰调试画面：两种构建的分叉收在 DebugHooks 一处（Release 里钩子什么都不做）；调试代码放 App/Sources/UI/Debug，演示数据在 Seed.swift" \
  '^\s*#(?:if|elseif)\b.*\bDEBUG\b' 'App/Sources/UI/Debug/**' '**/CueStore/Seed.swift'
forbid "色值只在色板（AppGroup/Palette.swift）：界面取 palette 的令牌，新颜色先进色板、定语义名与浅深两档，一样东西只有一份颜色" \
  '\b(?:Color|UIColor|NSColor|CGColor)\(\s*(?:hex|red|white|hue|srgbRed|calibratedRed|displayP3Red|deviceRed|calibratedWhite)\s*:' \
  'App/AppGroup/Palette.swift' 'App/Sources/UI/Debug/**' '**/Tests/**'
forbid "不用系统色与系统灰（.secondary、.gray、NSColor.labelColor…）：冷灰与系统蓝和纸墨并排是两套颜色；次要字用 palette.ink2、辅助字 ink3、浅底 fill" \
  '(?<![\w.])(?:Color\.|\.)(?:white|gray|grey|red|green|blue|orange|yellow|purple|pink|mint|teal|cyan|indigo|brown|accentColor)\b(?!\s*:)|\b(?:UIColor|NSColor)\.(?!clear\b)[a-z]\w*|(?:foregroundStyle|AnyShapeStyle|\.background|\.fill|\.tint)\(\s*\.(?:primary|secondary|tertiary|quaternary|quinary)\b|\.(?:secondary|tertiary|quaternary|quinary)\.opacity' \
  'App/AppGroup/Palette.swift' 'App/Sources/UI/Debug/**' '**/Tests/**'
forbid "不在界面里给颜色叠透明度：每处各写一个透明度就多出一档颜色。用色板里现成的档（ink2、ink3、hair、fill、track、selection、wash…），没有就进色板加一个；渐变的透明端写 .opacity(0)" \
  '(?:palette\.\w+|Color\.\w+|\.black|\.white)(?:\([^()]*\))?\.opacity\((?!0\))' \
  'App/AppGroup/Palette.swift' 'App/Sources/UI/Debug/**'
forbid "不用系统符号：全 App 的图标都是自家墨块符号（design/tools/cue-symbols.py 生成），经 Icon 按意思取；缺哪个就在生成器里画、在 Icon 里加一个意思" \
  '\b(?:systemName|systemImage|systemSymbolName)\b'
forbid "图标只经 Icon（Theme/Icon.swift）按意思取：哪个意思画成哪个符号只在那里写一处。用 Image(.名)、Label(_:icon:)、Button(_:icon:)、Menu(_:icon:)、Icon.platformImage；出错是 .failure、等你是 .waiting" \
  '\b(?:Image|UIImage|NSImage)\((?:named:\s*|symbolName:\s*)?"cue\.' '**/Theme/Icon.swift'
forbid "说的话只有一条路 Workspace.speak（Speaking.swift）：同步清空输入框、写一条记录、后台立即上传，界面不等上传与结果；别处直接写记录会长出第二套发消息的写法" \
  '(\baddCueMessage\(\s*\.you\b|\bstore\.(requestDelivery|speak)\()' '**/Workspace/Speaking.swift' '**/CueAgent/CueTools.swift' '**/Tests/**' 'App/Sources/UI/Debug/**'
forbid "界面上请求到哪了只读 Speech.trip（发送中、已送达、没能送达，含超时与本机同步不通）：直接看请求的原始状态会长出第二套状态机，超时与断网时说法对不上" \
  '\.isOpen\b|\.status\s*[!=]=\s*\.known\(\.(?:pending|executing|succeeded|failed)\)|\.status\.known\b' \
  'App/Sources/[!U]*/**' 'App/Sources/*.swift' 'App/Sources/UI/Debug/**' 'App/Tests/**' 'CuePadKit/**'
forbid "一行里用“·”隔开几段的字只经 Dotted 或 Dot（Atoms.swift）：屏幕写“·”、读屏读逗号；直接拼的分隔点读屏会念出来" \
  '(?: · |Text\("·"\))' 'App/AppGroup/Dotted.swift' '**/Components/Atoms.swift' '**/PiProgress.swift' 'App/Sources/UI/Debug/**' 'App/Tests/**' 'CuePadKit/**'
forbid "你说出去的话用 SpeechBubble 画（状态只从记录推出，见 Speech）；UserBubble 只给已进对话的话（会话对话与近况）" \
  '\bUserBubble\s*\(' '**/Components/PiBubbles.swift' '**/Components/PiConversation.swift' '**/Components/PiConversationBlocks.swift'

# 长按菜单带预览要跨行认（菜单闭包在中间），单独一条多行规则
hits="$(rg -U --pcre2 --line-number --no-heading --type swift --glob '!App/Sources/UI/iOS/Components.swift' \
  -e '\.contextMenu\s*(?:\(menuItems:|\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}\s*preview:)' -- App CuePadKit)" && rc=0 || rc=$?
[ "$rc" -le 1 ] || exit "$rc"
if [ "$rc" = 0 ]; then
  printf '%s\n  → 带预览的长按菜单用 contextMenu(menu:lifting:)（iOS/Components.swift）：预览是系统另起的一层宿主、不继承环境，读 Workspace 这类对象直接 fatalError（2610152015 长按任务崩溃）\n\n' "$hits"
  status=1
fi

# 调试目录与产品同一个 target：文件不整个包在 DEBUG 里，Debug 构建与测试照过，Release 编不过或把调试代码发出去（350b9a47）。
# DebugHooks.swift 是两种构建共用的入口，例外
for file in App/Sources/UI/Debug/*.swift; do
  [ "${file##*/}" = DebugHooks.swift ] && continue
  first="$(grep -m1 -E '^[[:space:]]*#if\b' "$file" || true)"
  [[ "$first" == *DEBUG* ]] && continue
  printf '%s\n  → 调试目录的文件整个包在 #if DEBUG（可加平台条件）里，第一条 #if 就要带 DEBUG；两种构建都要的放 DebugHooks.swift\n\n' "$file"
  status=1
done

exit $status
