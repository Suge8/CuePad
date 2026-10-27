#!/usr/bin/env bash
# 源码约束检查：规则多是"某写法只准出现在白名单路径里"（forbid），另有调试目录的整文件门；命中就列出位置、原因与该用什么，退出 1。
# 用法：lint.sh [--staged]   默认查工作区；--staged 查暂存区里的内容（提交钩子用，结论对应实际提交）。xc.sh check 跑默认模式。
# 只扫 App 与 CuePadKit 的 Swift，// 之后的注释不算；另查落地页的色令牌与色板同值。
# 每条规则的原因与替代只写在它的报错里；新规则先在一个真实违规（历史提交或临时注入）上证明会红再加。
set -euo pipefail
cd "$(dirname "$0")/../.."
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
forbid "动画曲线只用 Motion 的几种（AppGroup/Motion.swift，按用途分、数值与理由在它的头注释）：各处另写的弹簧、缓动是又一套手感，减弱动态效果也各管各的。软糖换拍子（Jelly）是按进度走的编排" \
  '(?:(?<![\w.])|\bAnimation)\.(?:spring|easeOut|easeIn|easeInOut|timingCurve|smooth|snappy|bouncy|interactiveSpring|interpolatingSpring|linear)\(' \
  'App/AppGroup/Motion.swift' '**/Theme/Jelly.swift'
forbid "自定义转场的 body 写成 nonisolated func：协议标的是主线程，iOS 上 SwiftUI 却在渲染线程求值，body 继承来的主线程隔离让里面的闭包一调就崩；只在类型上写 nonisolated 不够（理由在 BoardFlight.swift 的 board）" \
  '(?<!nonisolated )func body\(content: Content, phase: TransitionPhase\)'
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
forbid "图标只经 Icon（Theme/Icon.swift）按意思取自家墨块符号（design/tools/cue-symbols.py 生成），不用系统符号：哪个意思画成哪个符号只在那里写一处，缺哪个就在生成器里画、在 Icon 里加一个意思。用 Image(.名)、Label(_:icon:)、Button(_:icon:)、Menu(_:icon:)、Icon.platformImage；出错是 .failure、等你是 .waiting。扩展里没有 Icon，经 WidgetIcon" \
  '\b(?:systemName|systemImage|systemSymbolName)\b|\b(?:Image|UIImage|NSImage)\((?:named:\s*|symbolName:\s*)?"cue\.' \
  'App/Widget/WidgetIcon.swift'
forbid "说的话只有一条路 Workspace.speak（Speaking.swift）：同步清空输入框、写一条记录、后台立即上传，界面不等上传与结果；别处直接写记录会长出第二套发消息的写法" \
  '(\baddCueMessage\(\s*\.you\b|\bstore\.(requestDelivery|speak)\()' '**/Workspace/Speaking.swift' '**/CueAgent/CueTools+Say.swift' '**/Tests/**' 'App/Sources/UI/Debug/**'
forbid "界面上请求到哪了只读 Speech.trip（发送中、已送达、没能送达，含超时与本机同步不通）：直接看请求的原始状态会长出第二套状态机，超时与断网时说法对不上" \
  '\.isOpen\b|\.status\s*[!=]=\s*\.known\(\.(?:pending|executing|succeeded|failed)\)|\.status\.known\b' \
  'App/Sources/[!U]*/**' 'App/Sources/*.swift' 'App/Sources/UI/Debug/**' 'App/Tests/**' 'CuePadKit/**'
forbid "一行里用“·”隔开几段的字只经 Dotted 或 Dot（Atoms.swift）：屏幕写“·”、读屏读逗号；直接拼的分隔点读屏会念出来" \
  '(?: · |Text\("·"\))' 'App/AppGroup/Dotted.swift' '**/Components/Atoms.swift' '**/PiProgress.swift' 'App/Sources/UI/Debug/**' 'App/Tests/**' 'CuePadKit/**'
forbid "你说出去的话用 SpeechBubble 画（状态只从记录推出，见 Speech）；UserBubble 只给已进对话的话（会话对话与近况）" \
  '\bUserBubble\s*\(' '**/Components/PiBubbles.swift' '**/Components/SpeechBubble.swift' '**/Components/PiConversation.swift' '**/Components/PiConversationBlocks.swift'
# 例外：小组件与实时活动（扩展里没有 PressStyle）；设置里的网页链接（下划线、手形，同系统链接）；输入框里图片角上的移除（压在图片的暗底上，不铺悬停底）
forbid "自绘的可点控件用 PressStyle（按种类 Press）或 RowStyle，不用 .plain/.borderless：Mac 的悬停淡底与按下只在这两处，用了 plain 指针过去没有回应（docs/ui.md 悬停）" \
  'buttonStyle\(\.(?:plain|borderless)\)' 'App/Sources/UI/iOS/**' '**/*+iOS.swift' 'App/Widget/**' '**/Settings/SettingRow.swift' '**/Components/Composer+Attachments.swift'

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

# 落地页与 App 同一套颜色：落地页令牌里与 Palette 同名的（--signature-fill 对 signatureFill），浅、深两档都要与色板相等。
# 只认两种写法：#rrggbb，与 color-mix(in srgb, var(--另一个令牌) N%, transparent)（对应色板里的 .opacity）
python3 - App/AppGroup/Palette.swift ../landing/src/styles/base.css <<'PY' || status=1
import re, sys
palette, css = (open(p).read() for p in sys.argv[1:])

def side(expr, dark):
    "色板里一档的值：('#rrggbb', 1.0) 或 (底色令牌名, 透明度)；认不出返回 None"
    m = re.fullmatch(r"Color\(hex: 0x(\w{6})\)", expr.strip())
    if m: return ("#" + m[1].lower(), 1.0)
    m = re.fullmatch(r"(\w+)\.opacity\((.+)\)", expr.strip())
    if not m: return None
    a = re.sub(r"^highContrast \? [\d.]+ : ", "", m[2].strip())
    a = amounts.get(a, a)
    d = re.fullmatch(r"\(?dark \? ([\d.]+) : ([\d.]+)\)?", a)
    a = d[1 if dark else 2] if d else a
    return (m[1], float(a)) if re.fullmatch(r"[\d.]+", a) else None

# 透明度写成具名量的（ink.opacity(fillAmount)），先换回它的式子
amounts = dict(re.findall(r"var (\w+): Double \{ (.+?) \}", palette))
theirs = {}
for name, body in re.findall(r"^    var (\w+): Color \{(.*?)\}$", palette, re.M | re.S):
    body = " ".join(body.split())
    if m := re.fullmatch(r"dark \? (.+?) : (.+)", body):
        theirs[name] = (side(m[2], False), side(m[1], True))
    elif m := re.search(r"case \(false, false\): (Color\(hex: 0x\w{6}\)).*case \(true, false\): (Color\(hex: 0x\w{6}\))", body):
        theirs[name] = (side(m[1], False), side(m[2], True))
    else:
        theirs[name] = (side(body, False), side(body, True))

def css_side(v):
    v = v.strip()
    if re.fullmatch(r"#[0-9a-fA-F]{6}", v): return (v.lower(), 1.0)
    m = re.fullmatch(r"color-mix\(in srgb, var\(--([\w-]+)\) ([\d.]+)%, transparent\)", v)
    return (re.sub(r"-(\w)", lambda c: c[1].upper(), m[1]), round(float(m[2]) / 100, 4)) if m else None

bad = []
for name, value in re.findall(r"^\s*--([\w-]+):\s*([^;]+);", css, re.M):
    key = re.sub(r"-(\w)", lambda c: c[1].upper(), name)
    if key not in theirs: continue
    value = " ".join(value.split())
    m = re.fullmatch(r"light-dark\(\s*(.+?),\s*((?:#|color-mix).+)\)", value)
    ours = (css_side(m[1]), css_side(m[2])) if m else (css_side(value),) * 2
    if None in ours or None in theirs[key]:
        bad.append(f"--{name}：认不出写法（落地页 {value}）")
    elif ours != theirs[key]:
        fmt = lambda p: " / ".join(f"{c}" + ("" if a == 1 else f" {a:g}") for c, a in p)
        bad.append(f"--{name}：落地页 {fmt(ours)}，色板 {fmt(theirs[key])}（浅 / 深）")
if bad:
    print("landing/src/styles/base.css\n" + "\n".join("  " + b for b in bad))
    print("  → 落地页与 App 只有一套颜色，出处是 Palette.swift：改色先改色板，再把落地页同名令牌改成同值；落地页自己要的颜色另起不与色板同名的令牌\n")
    sys.exit(1)
PY

exit $status
