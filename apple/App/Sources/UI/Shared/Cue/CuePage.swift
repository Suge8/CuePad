import CueStore
import SwiftUI
#if os(macOS)
import CuePi
#endif

/// Cue 页（Mac 内容区的一页、iPhone 与 iPad 侧栏最上面那一行点进的页、iPad 右侧面板；iPhone 打开 App 就在这一页），与会话页同一套消息版式：
/// 页头一直在（头像、名字、此刻在做什么；Mac 在窗口工具栏，是 `CueTitle`；手机与 iPad 是浮在对话上的 `CueHeader`，点开是在做、等你与记忆的面板）；
/// 中间是对话：你的话是右侧牛皮纸色的气泡，Cue 的话是左侧纸做的气泡（`Bubble`、`CueSays`），它第一次提到一件活时气泡底下一行这件活（`CueTaskLine`），
/// 同一边连着说的几颗收紧成一串，隔了一阵的地方居中写几点（`ChatTimeMarker`）；经过、动态与分隔不是气泡，是旁注与居中的标记（`NoteLine`、`ChatMarker`），
/// 你发起的一轮在你的话之后先是这一轮的经过（`RoundProcess`，同会话页：在跑时实时展开，做完收成一行），这一轮说的话与结果按先后在它之后；
/// 经过清单里"对你说"那一条点它回到对话里的原处。连着的动态（含 Cue 自己醒来那几轮的经过）折成一行旁注（`CueNotes`），
/// 它换了新上下文的地方一条分隔（`CueRenewal`，点开是交接备忘），末尾是它此刻在做什么（`CueEnding`）；
/// 对话区与会话页是同一个（`ChatColumn`：排开、刻度滑条、跳转与描圈）；底部是"等你"（`CueWaitingDock`）与输入框（`CueComposer`）。
/// 对话第一帧就排好（`observing` 当场读），停在最新处。
/// Cue 住在别的设备上、本机正在和 iCloud 对时（`AppServices.isCatchingUp(on:)`）页头写"正在同步"，这期间到的话先不滑上来，
/// 对完一次滑到最新（`ChatColumn` 的 `holding`）。
/// Cue 在做的事在任务与 Agent 页里看，这里不另列。
/// 页面只读写库：写一条你的消息就是对 Cue 说话，Cue 住在哪台 Mac 都一样。"Cue 记得什么"（`CueMemoryPage`）在 Mac 的"⋯"里、手机页头的面板里；
/// Cue 在这台 Mac 值班时 Mac 的"⋯"里还有"运行情况"，在右侧开一栏（`CueRunPanel`）。
struct CuePage: View {
    /// iPad 右侧面板里：没有自己的顶栏（页头浮在面板顶上）。
    var inPanel = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var thread: CueThread?
    @State private var follow = ChatFollow()
    @State private var opened: PreviewOpening?
    /// 对话那一列的宽：离屏远的段换成的空白按它估高（`ChatSegments`）。
    @State private var width: CGFloat = 0
    @Environment(\.chatHighlight) private var highlight
    /// "等你"卡正在来去（`CueWaitingDock.moving`）：对话先不往上滑。
    @State private var docking = false

    #if os(macOS)
    private static let readingWidth: CGFloat = 760
    private static let inset: CGFloat = 24
    #else
    private static let readingWidth: CGFloat = 640
    private static let inset: CGFloat = 16
    #endif

    private var cue: CueWatch { workspace.cue }

    var body: some View {
        page
            .observing(services.store, into: $thread, onError: workspace.fail) { try CueThread.read(from: $0) }
            .previewPresenter($opened)
            .panel(isPresented: Bindable(cue).showsMemory) { CueMemoryPage() }
            .modifier(CueViewing(active: active))
            .onChange(of: thread != nil, initial: true) { _, loaded in
                guard loaded else { return }
                DebugHooks.mark("cue")
            }
    }

    // MARK: 平台

    #if os(macOS)
    private var page: some View {
        HStack(spacing: 0) {
            FloatingReply {
                chat
            } reply: {
                bottom
                    .padding(.horizontal, Self.inset).padding(.bottom, 16)
                    .frame(maxWidth: Self.readingWidth)
            }
            if cue.showsRun, let keeper = services.cue.keeper {
                CueRunPanel(keeper: keeper)
                    .padding([.trailing, .bottom], 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: cue.showsRun)
        .background(palette.desk)
    }
    #else
    /// 页头浮在对话上（`CueHeader`），对话让出固定的一段：页头展开成面板时对话不重排。iPhone 上页头在导航栏那一排里，左边是系统的返回
    /// （自带顶上一排的页的规则，同搜索页）；宽屏与右侧面板里列表就在旁边，没有返回。
    /// "等你"卡与输入框浮在对话底上（`FloatingReply`，同 Mac；在键盘之上）：不做成底下那一栏（安全区）——栏一变矮（发出时输入框收回一行、
    /// 卡沉下去）可见区当帧变高、系统把对话一下拉下去，发出的话一两帧后才到、再滑上来；栏一变高（卡升起）系统当帧挪、滚动区下一帧才跟上。
    private var page: some View {
        FloatingReply(backed: false) {
            chat
        } reply: {
            bottom
                .padding(.horizontal, 12).padding(.bottom, 8)
                .frame(maxWidth: Self.readingWidth)
        }
            .scrollDismissesKeyboard(.interactively)
            .fadesUnderBars(throughTopRow: inBar)
            .safeAreaPadding(.top, CueHeader.reserve(inBar: inBar))
            .overlay(alignment: .top) { CueHeader(inBar: inBar) }
            .navigationTitle(cue.name)
            // 标题只给读屏与系统；iPhone 上标题那一格让给页头的点按区（`inNavigationBarRow`）
            .toolbar(removing: inBar ? nil : .title)
    }

    /// 页头在导航栏那一排里（iPhone）。
    private var inBar: Bool { !inPanel && sizeClass == .compact }
    #endif

    // MARK: 对话

    /// 读不出来时也排一个真的视图：读库的订阅挂在页上，等视图出现才启动（docs/ui.md）。
    /// 还没说过话时是空态（`EmptyState`）：它自我介绍，下一步就是下面的输入框（没启用时是启用卡）。
    @ViewBuilder private var chat: some View {
        Group {
            if let thread, !thread.rows.isEmpty {
                conversation(thread)
            } else if thread != nil {
                EmptyState(mascot: .hello, title: "我是 \(cue.name)", message: cue.canHear ? "要做什么，直接在下面跟我说" : nil, waitsForSync: true)
                    .padding(.horizontal, Self.inset)
                    .frame(maxWidth: Self.readingWidth, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
            } else {
                Color.clear
            }
        }
    }

    /// 只排开铺满可见区要的那几格（`paging`）：打开时铺一屏，离最早那头不到一屏时（打开后紧接着就是）往上再铺一屏；
    /// 每 `segment` 格一段地排，离屏远的段换成同高的空白（`ChatSegments`），发出一句时只重排最新那段。一格多高要排出来才知道，
    /// 这里按每格至少多高（`floor`）往上数：数到的只会多不会少，第一帧就铺满、不露空白（不估真实的高：估高了就排少了，
    /// 打开时接着一段段地补，按字数估的高在真实库上排少了、更慢）。
    private func conversation(_ thread: CueThread) -> some View {
        let rows = thread.rows
        return ChatColumn(
            followKey: FollowKey(thread, live: cue.presence.progress != nil), readingWidth: Self.readingWidth, inset: Self.inset, follow: $follow,
            marks: thread.marks, ids: rows.map(\.id), paging: Self.paging(thread),
            holding: services.isCatchingUp(on: cue.hostID) || docking
        ) { window in
            let first = max(0, rows.count - window.count)
            let lastYou = thread.messages.last { $0.author == .known(.you) }?.id
            VStack(alignment: .leading, spacing: 0) {
                if first > 0 { EarlierRow(count: window.earlier, action: window.showEarlier) }
                let live = live
                ChatSegments(
                    items: rows, size: Self.segment, from: first, width: width, spare: Self.spare, pinned: { $0.contains { $0.id == highlight } }
                ) { items in
                    CueSegment(rows: items.map { item in
                        CueRow(
                            row: item, ref: item.taskID.flatMap { thread.tasks[$0] }, joined: thread.joined.contains(item.id), stamp: thread.stamps[item.id],
                            delivered: item.id == lastYou, live: live.flatMap { item.contains(round: $0.round) ? $0 : nil }, opened: $opened)
                    })
                    .equatable()
                }
                CueEnding(newestSaid: thread.messages.last { $0.author == .known(.cue) }?.createdAt, joined: rows.last?.speaker == .leading)
            }
            #if os(iOS)
            // 手机上对话里的字不开行内选择：长按出的是消息菜单，挑字走菜单里的"选择文本"（同会话页）
            .environment(\.inlineTextSelection, false)
            #endif
            // 刻度滑条按 id 跳到某一格（`ChatFollow.jump`）：滚动区只认滚动目标布局里的行
            .scrollTargetLayout()
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
            .animation(Motion.quick, value: cue.presence.progress)
            // 发出一句时"已送达"从上一句挪到这一句：上一句收起那行字的高与对话上滑走同一条曲线（`ChatScroll.slide`），
            // 不然下面各格一下顶上去，可见的整段先跳一截再滑
            .animation(Motion.spatial(Motion.move, reduceMotion: reduceMotion), value: lastYou)
        }
    }

    /// 在跑的那一轮（Cue 此刻的状态记着是哪一行）此刻的结尾；不在跑为 nil。
    private var live: CueLiveRound? {
        let presence = cue.presence
        guard let round = cue.round, let shown = presence.shown, let progress = presence.progress else { return nil }
        return CueLiveRound(round: round, ending: .live(shown, doing: progress, step: presence.isUsingTool ? RoundProcess.icon(.other) : nil))
    }

    /// 一段几格；屏上那几段上下各留几段真的（`ChatSegments`）。Cue 的回答长、一段要排几十毫秒（真实库），只留一段的话
    /// 来回翻几屏时每拆了又建一段就卡一下；留八段时翻动与整段都挂着一样顺，挂着的仍有上限。
    static let segment = 6, spare = 8

    /// 一格上面空多少：同一边连着说的收成一串，你开始说的新一轮与上一轮拉开，其余（Cue 接你的话、经过、动态、分隔）是一般的间距。
    /// `speaker`：这一格是谁的气泡（`CueThread.Row.speaker`），不是气泡为 nil。
    static func gap(before speaker: HorizontalEdge?, joined: Bool) -> CGFloat {
        if joined { return Bubble.joinedGap }
        return speaker == .trailing ? 32 : 16
    }

    /// 打开与往上翻都铺一屏（`conversation`），按每格至少多高（`floor`）从下往上数，只算数到的那几格。
    private static func paging(_ thread: CueThread) -> ChatPaging {
        let rows = thread.rows
        func count(filling size: CGSize, above: Int) -> Int {
            // 字排开的宽不超过可见区与阅读栏：按这么宽折行，折出的行只会比真的少
            let width = min(size.width, readingWidth)
            var sum: CGFloat = 0, count = 0
            for row in rows[..<above].reversed() where sum < size.height {
                sum += floor(row, joined: thread.joined.contains(row.id), stamped: thread.stamps[row.id] != nil, width: width)
                count += 1
            }
            return max(count, 1)
        }
        return ChatPaging(first: { count(filling: $0, above: $1) }, step: { count(filling: $0, above: $1) })
    }

    /// 一格至少多高（连同上面的间距与时间）：气泡里的字至少排几行（`lines`，一行至少 `MinimumText.line`），结果卡另有交付物的一排
    /// （`strip`，比最矮的那种还矮）与下面那件活一行，旁注、经过与分隔至少一行小字（`note`）。只能数多、不能数少（数少了第一帧铺不满）。
    private static func floor(_ row: CueThread.Row, joined: Bool, stamped: Bool, width: CGFloat) -> CGFloat {
        let note: CGFloat = 12, strip: CGFloat = 60
        let above = stamped ? 28 + note + 10 : gap(before: row.speaker, joined: joined)
        let bubble = Bubble.padding.top + Bubble.padding.bottom
        func text(_ message: CueMessage) -> CGFloat { MinimumText.line * CGFloat(lines(message.text, width: width)) }
        let body: CGFloat = switch row {
        case .you(let message), .cue(let message, _): bubble + text(message)
        case .result(let message, _, _): bubble + text(message) + note + strip
        case .notes, .process, .renewed: note
        }
        return above + body
    }

    /// 气泡里最小的字（代码块；iOS 按动态字体最小的一档）：一行至少多高、一个全角字至少多宽。
    private enum MinimumText {
        #if os(macOS)
        static let line: CGFloat = 18, wide: CGFloat = 13
        #else
        static let line: CGFloat = 14, wide: CGFloat = 11
        #endif
    }

    /// 原文在 `width` 宽里至少排几行。每个不空的行至少一行（段落里的换行照原样换，见 `MarkdownBlock`；代码块的围栏与表格的对齐行不排出来，不算）；
    /// 长的行折成几行只按全角字算（每个至少 `MinimumText.wide` 宽）：半角的不算（链接地址、行内记号不显示，窄的字母也窄），
    /// 表格行（横着滚、不折）与图片行只算一行。
    private static func lines(_ text: String, width: CGFloat) -> Int {
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("```") { continue }
            if trimmed.hasPrefix("|") || trimmed.contains("![") {
                if MarkdownTable.alignments(trimmed) == nil { count += 1 }
                continue
            }
            let wide = trimmed.unicodeScalars.reduce(0) { $0 + (isWide($1) ? 1 : 0) }
            count += max(1, Int((CGFloat(wide) * MinimumText.wide / width).rounded(.up)))
        }
        return max(count, 1)
    }

    /// 全角：汉字与假名、谚文、全角标点（排出来至少一个字宽）。
    private static func isWide(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3000...0x30FF, 0x3400...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF01...0xFF60: true
        default: false
        }
    }

    /// 有新内容：多了消息、有一条被答了、"等你"变了、末尾的进展出现或收起。
    private struct FollowKey: Equatable {
        var count: Int
        var last: Date?
        var waiting: Int
        var live: Bool

        init(_ thread: CueThread, live: Bool) {
            count = thread.messages.count
            last = thread.messages.last?.modifiedAt
            waiting = thread.waiting.count
            self.live = live
        }
    }

    // MARK: 底部

    /// 浮在对话底上的一块："等你"卡、启用卡与输入框。
    private var bottom: some View {
        VStack(spacing: 0) {
            if let thread {
                CueWaitingDock(waiting: thread.waiting, tasks: thread.tasks, open: { opened = $0 }, moving: $docking)
            }
            if !cue.canHear {
                CueEnableCard().padding(.bottom, 8).transition(.opacity)
            }
            #if os(iOS)
            CueComposer(style: .page, focusRequests: inPanel ? 0 : navigation.cueFocusRequests) { follow.sent() }
            #else
            CueComposer(style: .page) { follow.sent() }
            #endif
        }
        .animation(Motion.quick, value: cue.canHear)
    }
}

/// 对话里的一段（`CuePage.segment` 格，`ChatSegments`）：只按各格的内容比较。
private struct CueSegment: View, Equatable {
    let rows: [CueRow]

    nonisolated static func == (a: Self, b: Self) -> Bool { a.rows.map(\.key) == b.rows.map(\.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.row.id) { $0.equatable() }
        }
    }
}

/// 对话里的一格，连同上面的时间与间距。只按自己的输入比较（`equatable()`）：对话里来了一句、Cue 的状态变了，别的格子不重算——
/// 发出一句的那一刻对话要重排，每格都重算的话那一帧就掉了。要的那件活、在跑的那一轮、"已送达"都只交给用得着的那一格。
private struct CueRow: View, Equatable {
    let row: CueThread.Row
    let ref: CueTaskRef?
    let joined: Bool
    let stamp: Date?
    /// 你最后一句：下面写"已送达"。
    let delivered: Bool
    let live: CueLiveRound?
    @Binding var opened: PreviewOpening?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    /// 这一格排出来什么样只看这几样。
    nonisolated struct Key: Equatable {
        let row: CueThread.Row, ref: CueTaskRef?, joined: Bool, stamp: Date?, delivered: Bool, live: CueLiveRound?
    }

    nonisolated var key: Key { Key(row: row, ref: ref, joined: joined, stamp: stamp, delivered: delivered, live: live) }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }

    var body: some View {
        if let stamp { ChatTimeMarker(date: stamp).padding(.top, 28) }
        content.padding(.top, stamp != nil ? 10 : CuePage.gap(before: row.speaker, joined: joined))
    }

    @ViewBuilder private var content: some View {
        let cue = workspace.cue
        switch row {
        case .you(let message):
            SpeechBubble(said: .cue(message, host: cue.hostID), box: Bindable(cue).draft, showsDelivered: delivered, joined: joined) { _ in
                MessageActions(text: message.text, kind: .cue)
            }
        case .cue(let message, _):
            CueSays(message: message, task: ref, joined: joined, arrives: !swapsInPlace)
        case .result(let message, _, let deliverables):
            if let ref { CueResultCard(message: message, ref: ref, deliverables: deliverables) { opened = $0 } }
        case .notes(let notes):
            CueNotes(notes: notes, live: live).padding(.leading, Bubble.noteInset)
        case .process(let message):
            RoundProcess(tools: message.tools, ending: CueLiveRound.ending(of: message, in: live)).padding(.leading, Bubble.noteInset)
        case .renewed(let handoff):
            CueRenewal(handoff: handoff, name: cue.name)
        }
    }

    /// Cue 的话原位换下正在说的话（Cue 在这台 Mac 值班时），不淡入。
    private var swapsInPlace: Bool {
        #if os(macOS)
        services.cue.keeper != nil
        #else
        false
        #endif
    }
}

/// Cue 在跑的那一轮：经过那一行（`round`）此刻的结尾，其余经过不记用时。
/// 交给对话里各格的是这个值而不是闭包：闭包每次都不相等，Cue 的状态一变（被叫醒、在想→用工具）对话里每一格都要重算。
nonisolated struct CueLiveRound: Equatable {
    let round: UUID
    let ending: RoundProcess.Ending

    static func ending(of message: CueMessage, in live: CueLiveRound?) -> RoundProcess.Ending {
        guard let live, live.round == message.id else { return .took(nil) }
        return live.ending
    }
}

/// Cue 从这里起换了新上下文：与会话页的压缩同一条分隔（`ContextBoundary`），点开是换新时写下的交接备忘；从刻度滑条跳过来时描一圈。
private struct CueRenewal: View {
    let handoff: CueMessage
    let name: String
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        ContextBoundary(title: "从这里起 \(name) 换了新上下文", time: handoff.createdAt, memo: handoff.text, highlighted: highlight == handoff.id)
    }
}

/// Cue 页对话的末尾：它在做事、这一轮还没调过工具（经过那一行还没写下）时是一行此刻在做的（`RoundProcess` 的那一行，同会话页）。
/// Cue 在这台 Mac 值班时，在回答你的一轮出字就换成逐字长出的正在说的话
/// （`CueKeeper.speech`，同会话页的 `SessionDraft`）：只有这个视图读它，出字时对话列表不重算；它与对话在同一次更新里拿到同一份对话，
/// 落库了（`PiDraft.landed`）就不再显示，换下是同一帧里的一减一加。已落库而 Cue 的状态还没歇下时也不冒出进展那一行（话已经说完）；
/// 中途转成工具调用时让位给进展那一行。进展那一行被换下时直接拿掉，不与正在说的话叠着淡出。别的 Mac 与手机只有进展那一行。
private struct CueEnding: View {
    /// 对话里最近一条 Cue 的话的时刻
    let newestSaid: Date?
    /// 对话最后一格是 Cue 的话：正在说的这句落库后与它连成一串，说着的时候就排成那个样子。
    let joined: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    #if os(macOS)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #endif

    var body: some View {
        #if os(macOS)
        let draft = services.cue.keeper?.speech.draft
        let landed = draft?.landed(newestReply: newestSaid) ?? false
        if let draft, !landed {
            // 与落库后的那句（`CueSays`）同一颗气泡、同一个位置，换下时正文不动
            BubbleWidth(fraction: Bubble.cueWidth, edge: .leading) {
                MarkdownText(source: draft.text).equatable().cueBubble(joined: joined)
            }
            .padding(.top, CuePage.gap(before: .leading, joined: joined))
            .transition(.asymmetric(insertion: Bubble.arrival(.leading, reduceMotion: reduceMotion), removal: .identity))
        } else if !landed {
            live
        }
        #else
        live
        #endif
    }

    @ViewBuilder private var live: some View {
        let presence = workspace.cue.presence
        if workspace.cue.round == nil, let shown = presence.shown, let progress = presence.progress {
            RoundProcess(tools: nil, ending: .live(shown, doing: progress, step: nil))
                .padding(.leading, Bubble.noteInset)
                .padding(.top, CuePage.gap(before: nil, joined: false))
                .transition(.asymmetric(insertion: .entry, removal: .identity))
        }
    }
}

/// Cue 页在前台时算一个在看的（`AppServices.cueViewers`）。Mac 的页离开后还挂着，所以按在不在前台算，不按出现与消失。
private struct CueViewing: ViewModifier {
    let active: Bool
    @Environment(AppServices.self) private var services
    @State private var counted = false

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { count(active) }
            .onDisappear { count(false) }
    }

    private func count(_ on: Bool) {
        guard on != counted else { return }
        counted = on
        services.cueViewers += on ? 1 : -1
    }
}
