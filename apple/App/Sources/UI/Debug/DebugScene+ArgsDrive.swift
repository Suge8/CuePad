#if DEBUG

nonisolated struct DriveArgs: Decodable, DebugArgGroup {
    static let prefix = ""
    /// `-CuePadAXDump YES`：界面起来 4 秒后把读屏看到的元素（标签、值、特征）按顺序写进资料库目录的
    let axDump: Bool
    /// `-CuePadAXFocus YES`：旁白每落到一个元素就往资料库目录的 `ax-focus.txt` 追加一行（同上的格式，再带它在屏上的框）
    let axFocus: Bool
    /// `-CuePadActivityDiagnostics YES`：隔离库里也留活动取证
    let activityDiagnostics: Bool
    /// `-CuePadActivityDiagnosticsRead <输出.json>`：`xc.sh activity-log` 用，只读导出活动取证；由 `ActivityDiagnosticReader` 直接读命令行，这里登记以便不被当成拼错的参数
    let activityDiagnosticsRead: String?
    /// `-CuePadBench interact|chatscroll|churn`（量完退出）：interact 单次交互的点击回合与掉帧，chatscroll（仅 Mac）长对话滚动，churn（仅 Mac）边加卡边拉宽窗口查布局反馈环
    let bench: String?
    /// `-CuePadBoardTour YES`：走一遍看板的各种变化
    let boardTour: Bool
    /// `-CuePadClick x,y[;x,y|esc|return|type:文字|cmd:键…]`（仅 Mac）：就绪后在主窗口里按顺序左键点几下，`esc`、`return`、`tab` 是按那个键，`cmd:键` 是按主菜单的快捷键（双击、拖、捏合等见 `DebugGestures+Mac.swift`）
    let click: String?
    /// `-CuePadClickGap <秒>`（默认 1.5）：`-CuePadClick` 几下之间的间隔
    let clickGap: Double?
    let closed: Double
    /// `-CuePadCommand YES`：从标准输入读命令（同步测量的实例用）
    let command: Bool
    /// `-CuePadCueBrain <可执行文件>`（仅 Mac）：Cue 的大脑换成这个替身（如 `scripts/cue-brain-stub.py`），量值班开销用
    let cueBrain: String?
    /// `-CuePadCueFlow YES`：走一遍从发送到回话的流程（量法见 `-CuePadCueFlowLog`）
    let cueFlow: Bool
    /// `-CuePadCueFlowLog <路径>`：同 `measureFlight` 的量法，量"发送"（send：从按下起）与"静止"（idle：走完之后 Cue 歇着、页面不动）各一段，一段一行 JSON 追加进这个文件
    let cueFlowLog: String?
    /// `-CuePadCueSays <秒>`：过这么久 Cue 说一句（配 `-CuePadVisitCue`、`-CuePadClosed`、`-CuePadReopen`）
    let cueSays: Double
    let cycle: Bool
    /// `-CuePadFlightLog <路径>`：叫醒、交给前后各量一段（帧间隔、掉帧、主线程 CPU、指令数与能量），一段一行 JSON 追加到这个文件
    let flightLog: String?
    /// `-CuePadForeground YES`（仅 Mac）：允许占前台（本机构建默认在后台）
    let foreground: Bool
    /// `-CuePadFreeze <秒>`：就绪后把主线程堵住这么久，核对卡住的记录
    let freeze: Double
    /// `-CuePadHover x,y[;x,y…]`（仅 Mac）：窗口里这几点上的按钮、行与卡画成指针停着的样子（坐标同 `-CuePadClick`）
    let hover: String?
    /// `-CuePadHoverSeconds <秒>`：停这么久后移开（从那一块出现起算），录提示条悬停停表、移开重新计满
    let hoverSeconds: Double?
    /// `-CuePadImportDelay <秒>`：把"附件还在存"拉长到能在界面上看见（配 `-CuePadSpeech press`；运行时的值在 `DebugHooks.importDelaySeconds`）
    let importDelay: Double
    /// `-CuePadInteractOnly 项,项`：`-CuePadBench interact` 只量列出的几项
    let interactOnly: String?
    /// `-CuePadNotice <文字>`：就绪后 5 秒弹一条带撤销的提示，按真实时长收
    let notice: String?
    /// `-CuePadPressAfter <秒>`（默认 3）：`-CuePadSpeech press` 在输入框出现这么久后按它的发送钮
    let pressAfter: Double?
    let relay: Double
    /// `-CuePadRelayKind say|start`：`-CuePadRelay` 只做其中一种
    let relayKind: String?
    /// `-CuePadReopen <秒>`：关上这么久后再打开（真的显示，会到前台），关着的这段中途把 Cue 此刻的状态写成用工具
    let reopen: Double
    let replyBlink: Double
    /// `-CuePadRightClick x,y`（仅 Mac，要 `-CuePadForeground YES`）：右键点一下，打开那里的系统菜单
    let rightClick: String?
    /// `-CuePadScrollDriver direct|process|hid`：`-CuePadBench chatscroll` 用哪种方式滚（方法限制见 `ChatScrollBench`）
    let scrollDriver: String?
    /// `-CuePadScrollPointer in|out`：热身之后把指针移到对话区中央（in）或窗口外的屏幕角落（out），量完放回
    let scrollPointer: String?
    /// `-CuePadSpeech press`：输入框出现 3 秒后按一下它的发送钮，录发出的那一下
    let speech: String?
    /// `-CuePadStream YES`（配 session 画面）：打开会话后像真的 Agent 那样一轮一轮追加：看新内容到达时跟随最新
    let stream: Bool
    /// `-CuePadTraceWait YES`（perf 脚本带着 CUEPAD_TRACE 时，_trace.sh）：写 `AWAIT trace <PID>` 停着，等脚本按 PID 开录了发来 SIGUSR1
    let traceWait: Bool
    /// `-CuePadVisitCue <秒>`：说完这么久去 Cue 页，停够读到它再回原来那页，录"别处时有提示、读过就没了"
    let visitCue: Double
    /// `-CuePadWaitKinds YES`：等你里各种问题都有（再一张 Cue 的删目录一问），已完成里一件带成果图
    let waitKinds: Bool
    /// `-CuePadWake <秒>`（配 `-CuePadDemo YES`，一直循环）：每隔这么久 Cue 被在线会话叫醒一次（配 `-CuePadFlightLog` 量开销）
    let wake: Double
}
#endif
