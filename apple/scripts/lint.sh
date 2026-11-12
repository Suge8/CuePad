#!/usr/bin/env bash
# 源码约束检查：规则多是"某写法只准出现在白名单路径里"（forbid），另有调试目录的整文件门；命中就列出位置、原因与该用什么，退出 1。
# 用法：lint.sh [--staged]   默认查工作区；--staged 查暂存区里的内容（提交钩子用，结论对应实际提交）。xc.sh check 跑默认模式。
# 只扫 App 与 CuePadKit 的 Swift，// 之后的注释不算；另查落地页的色令牌与色板同值，与 Pi 桥扩展改了升没升版本（只在默认模式）。
# 每条规则的原因与替代只写在它的报错里；新规则先在一个真实违规（历史提交或临时注入）上证明会红再加。
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

forbid "等待的转圈用 Spinner（LoopLayer.swift）：全 App 的转圈同一个样子、同一个颜色，交给渲染服务转、App 进程不参与" \
  '\bProgressView\b'
forbid "空态与出错页用 EmptyState，不用系统 ContentUnavailableView：全 App 空态统一成吉祥物加一句现状，品牌一致（a2e5df76）" \
  '\bContentUnavailableView\b'
# 唯一例外：启动失败时还没有窗口能挂 dialog
forbid "Mac 上的确认框用 dialog、浮层用 panel、选文件用 FilePicker（非模态 begin）：runModal 与 NSAlert 把主线程关在嵌套事件循环里，sheet 开关各约 300ms" \
  '\b(runModal|NSAlert)\b' 'App/Sources/macOS/AppDelegate.swift'
forbid "常驻循环动效只用 LoopLayer（Core Animation）：SwiftUI 的 repeatForever 与符号动效每帧在 App 进程里重算，静止的 Agent 页也占约 9% CPU（随值触发一次的 .nonRepeating 不常驻，不算）" \
  '(\brepeatForever\b|(?<!\()\.symbolEffect\((?![^)]*\.nonRepeating\b))' '**/LoopLayer.swift'
forbid "动画曲线只用 Motion 的几种（AppGroup/Motion.swift；UIKit 视图上经 Motion.Fade.animate）：另写的是又一套手感，减弱动态效果也各管各的。软糖换拍子（Jelly）是按进度走的编排" \
  '(?:(?:(?<![\w.])|\bAnimation)\.(?:spring|easeOut|easeIn|easeInOut|timingCurve|smooth|snappy|bouncy|interactiveSpring|interpolatingSpring|linear)|\bUIView\.animate)\(' \
  'App/AppGroup/Motion.swift' '**/Theme/Jelly.swift'
forbid "自定义转场的 body 写成 nonisolated func：协议标的是主线程，iOS 上 SwiftUI 却在渲染线程求值，body 继承来的主线程隔离让里面的闭包一调就崩；只在类型上写 nonisolated 不够（理由在 BoardFlight.swift 的 board）" \
  '(?<!nonisolated )func body\(content: Content, phase: TransitionPhase\)'
forbid "按时刻换字的文字用 LiveText（Moments.swift，不用系统时间文本的原因在它的注释里）" \
  '\.currentDate\b'
forbid "不用 DispatchQueue.main.asyncAfter：它取消不了。等事件用通知序列或 NextFrame，真要定时用可取消的 Task.sleep" \
  'DispatchQueue\.main\.asyncAfter'
forbid "不访问 NSTextView/UITextView 的 layoutManager：访问一次就把视图永久降级到 TextKit 1，用 textLayoutManager" \
  '\.layoutManager\b'
forbid "iOS 上不进读屏用 readerHidden（ReaderHidden.swift），按条件的与一直藏的都是：accessibilityHidden 只在显式无障碍容器里生效，直接挂在栈里或自己收成元素再挂，旁白照样念到（模拟器旁白实测：拍板卡图下的说明、回复框后面接点按的空层都念了，#67）；Mac 的无障碍树藏得住，Mac 独有文件不限；已合并成一个元素里的那句（按钮的标签、children: .combine）直接写，行尾注释以「合并」开头说明（容器会把它挡在合并外）" \
  '\.accessibilityHidden\((?!false\))(?!.*//\s*合并)' '**/ReaderHidden.swift' '**/macOS/**' '**/*+macOS.swift' '**/*+Mac.swift'
forbid "按名字取图用 Image(decorative:)，或经 Icon、BrandMark：Image(\"名字\") 拿资源名当读屏标签，旁白念出 cue.plus、cue.waiting（#67）；意思由所在控件的标签说" \
  '\bImage\(\s*"'
forbid "自绘玻璃只经 glass(in:)（Surfaces.swift）：材质统一 .regular，降低透明度、增强对比度时退回实底" \
  '\.glassEffect\(' '**/Theme/Surfaces.swift'
forbid "玻璃只挂在内容本身上（content.glass(in:)），不挂在空背景、空形状上（Color.clear、Rectangle() 这类再 .glass）：玻璃容器（GlassEffectContainer）把挂在空东西上的玻璃合成到同一层、画在旁边的字上面，名牌的字就这样被盖住过；字也要在玻璃里才随玻璃的明暗取色" \
  '(?:\bColor\.\w+|\b(?:Rectangle|RoundedRectangle|UnevenRoundedRectangle|ConcentricRectangle|Capsule|Circle|Ellipse|EmptyView|Spacer)\([^)]*\))(?:\s*\.\w+\([^()]*(?:\([^()]*\)[^()]*)*\))*\s*\.glass(?:Effect)?\('
forbid "产品代码不写 #if DEBUG，经 DebugHooks 碰调试画面：两种构建的分叉收在 DebugHooks 一处（Release 里钩子什么都不做）；调试代码放 App/Sources/UI/Debug，演示数据在 Seed.swift" \
  '^\s*#(?:if|elseif)\b.*\bDEBUG\b' 'App/Sources/UI/Debug/**' '**/CueStore/Seed.swift'
forbid "圆角只用 Radius 的几档（Theme/Radius.swift，按东西的种类分：chip、block、card、sheet、field）：各处自写的数是又一套手感，新东西先问它是哪一类；嵌在容器里的块用 Radius.nested 同心；胶囊与圆写 .capsule、.circle，不写半高" \
  '(?:\b[A-Za-z]*[cC]ornerRadius:\s*[\d.]|\b(?:topLeading|bottomLeading|bottomTrailing|topTrailing|top|bottom|leading|trailing)Radius:\s*[\d.]|\b(?:xRadius|yRadius|cornerWidth|cornerHeight):\s*[\d.]|\b\w*[rR]adius(?::\s*CGFloat)?\s*=\s*[1-9.])' \
  '**/Theme/**' 'CuePadKit/Tests/**'
# 例外：Debug 里演示用的别家界面（预发页、登录页、手机截图）有它们自己的字号；灵动岛的字号在扩展里（扩展没有 Typography）
forbid "字号只经 Typography（文字，Theme/Typography.swift）与 Glyph（图标，Theme/Glyph.swift）的几档，Theme 以外不写 .system(size: 数) 与 ofSize:、pointSize: 的数：各处自写的字号是又一套层级，新东西先问它是正文、说明还是哪一档图标；确要新档就在那两处按用途加一个" \
  '(?:\.system\(size:\s*[\d.]|\b(?:ofSize|pointSize):\s*[\d.])' \
  '**/Theme/**' 'App/Sources/UI/Debug/**' '**/Tests/**' 'App/Widget/IslandType.swift'
forbid "字体名称只在 Typography 选择：界面与编辑器复用同一角色，让系统按文字选择中英文字形，不在单个组件强制中文字体" \
  '(?:\b(?:CueFont|NSFont|UIFont)\(name:|\bFont\.custom\(|\.font\(\s*\.custom\()' \
  '**/Theme/Typography.swift' 'App/Sources/UI/Debug/**' '**/Tests/**'
forbid "额外行距只在 Typography 定义：输入、发送后的气泡、正文与测高复用同一阅读角色；紧凑文字按角色取值，不在组件里另写一套" \
  '(?:(?:\.lineSpacing\(\s*|\blineSpacing:\s*|\.lineSpacing\s*=\s*)(?:[1-9]|0\.\d*[1-9]))' \
  '**/Theme/Typography.swift' 'App/Sources/UI/Debug/**' '**/Tests/**'
forbid "投影只经 elevation 的几档（Theme/Surfaces.swift 的 Elevation，按浮多高分：hover、lifted、panel）：各处自写的半径与偏移是又一套手感，颜色随外观由色板给" \
  '\.shadow\(' '**/Theme/**' 'App/Sources/UI/Debug/**' '**/Tests/**'
forbid "字号只经 Typography 的角色与 Glyph，不写系统文字样式（.caption、.footnote、Font.subheadline…）：它们编进 Mac 是系统的小号（.caption、.footnote 10 点），低于 Mac 的 12 点下限；iOS 缺的角色在 Typography 里按用途加。扩展（Widget）里没有 Typography，例外" \
  '(?:\.font\(\s*\.(?:body|headline|subheadline|caption2?|footnote|callout|title[23]?|largeTitle)\b|\bFont\.(?:body|headline|subheadline|caption2?|footnote|callout|title[23]?|largeTitle)\b|\.system\(\.(?:body|headline|subheadline|caption2?|footnote|callout|title[23]?|largeTitle)\b)' \
  '**/Theme/**' 'App/Sources/UI/Debug/**' '**/Tests/**' 'App/Widget/**'
forbid "小东西冒出来、收回去用 Motion.pop（AppGroup/Motion.swift）：从 0.9 长到原大并淡入，减弱动态效果时只淡；各处写的 .scale 起点不一（0、0.6），从 0 长读作跳出来" \
  '(?:\.transition\(\s*|\bAnyTransition)\.scale\b' 'App/AppGroup/Motion.swift'
forbid "Mac 主窗口里从控件弹出的说明与小表单用 bubble(isPresented:) 或 HelpButton，不用系统 popover：它另起一扇窗，第一次弹 85～113ms，开着时主窗口的快捷键不响应（docs/layout.md）；设置窗口与只编进 iOS 的文件例外" \
  '\.popover\(' 'App/Sources/UI/iOS/**' '**/*+iOS.swift' 'App/Sources/UI/macOS/Settings/**' 'App/Sources/UI/Debug/**'
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
forbid "输入框经 Workspace.speak 同步取走草稿；消息落库经 AppServices.recordSpeech，语音身份原子复核只在 CueStore+VoiceRecovery；同一去处共用发送顺序，界面不等上传与执行结果" \
  '(\baddCueMessage\(\s*\.you\b|\bstore\.(requestDelivery|speak)\()' 'App/Sources/Services/AppServices+Speaking.swift' 'CuePadKit/Sources/CueStore/CueStore+VoiceRecovery.swift' '**/CueAgent/CueTools+Say.swift' '**/Tests/**' 'App/Sources/UI/Debug/**'
forbid "界面上请求到哪了只读 Speech.trip（发送中、已送达、没能送达，含超时与本机同步不通）：直接看请求的原始状态会长出第二套状态机，超时与断网时说法对不上" \
  '\.isOpen\b|\.status\s*[!=]=\s*\.known\(\.(?:pending|executing|succeeded|failed)\)|\.status\.known\b' \
  'App/Sources/[!U]*/**' 'App/Sources/*.swift' 'App/Sources/UI/Debug/**' 'App/Tests/**' 'CuePadKit/**'
forbid "一行里用“·”隔开几段的字只经 Dotted 或 Dot（Atoms.swift）：屏幕写“·”、读屏读逗号；直接拼的分隔点读屏会念出来" \
  '(?: · |Text\("·"\))' 'App/AppGroup/Dotted.swift' '**/Components/Atoms.swift' '**/SessionProgress.swift' 'App/Sources/UI/Debug/**' 'App/Tests/**' 'CuePadKit/**'
forbid "你说出去的话用 SpeechBubble 画（状态只从记录推出，见 Speech）；UserBubble 只给已进对话的话（会话对话与近况）" \
  '\bUserBubble\s*\(' '**/Components/Bubbles.swift' '**/Components/SpeechBubble.swift' '**/Components/Conversation.swift' '**/Components/ConversationBlocks.swift'
# 例外：小组件与实时活动（扩展里没有 PressStyle）；设置里的网页链接（下划线、手形，同系统链接）；输入框里图片角上的移除（压在图片的暗底上，不铺悬停底）
forbid "自绘的可点控件用 PressStyle（按种类 Press）或 RowStyle，不用 .plain/.borderless：Mac 的悬停淡底与按下只在这两处，用了 plain 指针过去没有回应（docs/ui.md 悬停）" \
  'buttonStyle\(\.(?:plain|borderless)\)' 'App/Sources/UI/iOS/**' '**/*+iOS.swift' 'App/Widget/**' '**/Settings/SettingRow.swift' '**/Components/Composer+Attachments.swift'
FORBID_IN=CuePadKit/Sources/CueSync forbid "同步里登记等待者、以后再答复的只用 Promise（SyncGeneration.swift），本代里的等待经 SyncGeneration.value：各写各的续体表会再长出各自认不认 stop、取消的那一套；把系统回调接成 async 的（读、传 iCloud 文件）例外" \
  '\bwith(?:Checked|Unsafe)(?:Throwing)?Continuation\b' \
  'CuePadKit/Sources/CueSync/SyncGeneration.swift' 'CuePadKit/Sources/CueSync/CloudDatabase+Files.swift'

# 业务规则只进 Services：UI 里给 AppServices 加方法，规则就散进了界面（界面的 Workspace 方法调 Services，不替它长方法）；AppServices.StartupIssue 这类嵌套类型的扩展不算
FORBID_IN=App/Sources/UI forbid "UI 下不写 extension AppServices：业务规则放 App/Sources/Services（AppServices+….swift），界面只调它" \
  '\bextension AppServices\b(?!\.)'
# 测试宿主就是正式版的 App 身份，.standard 就是正式版的偏好域
FORBID_IN="App/Tests CuePadKit/Tests" forbid "测试不碰 UserDefaults.standard：测试宿主就是正式版的 App 身份，读写的是真实偏好域；用库目录里具名的域（App/Tests/IsolationTests.swift）" \
  '\bUserDefaults\.standard\b'
# 拼装写法（一个个字段传）是演示与测试图方便的；真实写入只经 SessionSnapshot 的 update(_:)。参数可能换行，所以跨行认
FORBID_U=1 forbid "生产代码不调 StateRecorder.update(sessionID: …)：它只给 UI/Debug 与测试拼状态用；真实会话的状态经 SessionMirror 产出 SessionSnapshot，再 update(_:)" \
  '(?<!func )\bupdate\(\s*sessionID:' 'App/Sources/UI/Debug/**' '**/Tests/**'
FORBID_IN="CuePadKit/Sources/CueStore App/Sources/Services/AppServices+StrayFiles.swift" forbid "附件文件与资料库不按文件时刻定去留：拷贝、还原、同步会改写或带走时刻，按时刻猜「刚存的」曾删掉写者还没提交引用的文件（#102）。谁还要它只看库里的记录与引用、运行的持有（AttachmentRun 的锁）与草稿" \
  '\b(?:(?:(?:content|attribute)ModificationDate|contentAccessDate|creationDate|modificationDate|addedToDirectoryDate)(?:Key)?|st_[acmb]tim(?:e|espec)\w*|storedBefore)\b'
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

# 放行的测试只读或只写测试自己的：只读真实凭据（EvalBrain）、固定版本 Agent 的下载缓存（PinnedAgent）
forbid "家目录只经 UserHome（CueStore）取：读写各家 Agent 的走 AgentPaths（userHome、expanding，认环境给的 HOME，隔离实例与测试换得掉）；确要真实家目录的（显示 ~/…、展开用户写的 ~、缺省位置）用 UserHome。直接取绕过隔离，会读写真实的 ~/.claude、~/.pi" \
  '(\bhomeDirectoryForCurrentUser\b|\bNSHomeDirectory(?:ForUser)?\b|\bhomeDirectory\(forUser|\.homeDirectory\b|\b(?:expanding|abbreviatingWith)TildeInPath\b|getenv\("HOME"\)|processInfo\.environment\["HOME"\])' \
  '**/CueStore/UserHome.swift' '**/EvalBrain.swift' '**/PinnedAgent.swift'

FORBID_U=1 forbid "通知先订再消费：任务外先 let 流，任务里 for await 它。for await 那行才订，此前发的就丢了；不怕丢的行尾写「// 晚订：理由」" \
  'for (?:try )?await\b[^{]*?\bin [^{]*?\.notifications\(named:(?!.*// 晚订：)'

# 间距只经 Spacing 的几档（规则在 lint_spacing.py 头注释）
python3 "$scripts/lint_spacing.py" || status=1

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
