import CueStore
import SwiftUI
#if os(macOS)
import CuePi
#endif

/// Cue 页（Mac 内容区的一页、iPhone 的 Cue 标签、iPad 侧栏最上面与右侧面板），与会话页同一套消息版式：
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
    @Environment(\.pageActive) private var active
    #if os(iOS)
    @Environment(\.tabPageReady) private var tabPageReady
    @Environment(Navigation.self) private var navigation
    #endif
    @State private var thread: CueThread?
    @State private var follow = ChatFollow()
    @State private var opened: PreviewOpening?

    /// 最初排开最近几格，往上翻快到头时再排开这么多格（排开、跳转与刻度同会话页，见 `ChatColumn`）。
    private static let paging = ChatPaging(first: 40, step: 40)
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
                #if os(iOS)
                tabPageReady?()
                #endif
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
    /// 页头浮在对话上（`CueHeader`），对话让出固定的一段：页头展开成面板时对话不重排。标签栏布局下页头左边是设置（标签根页的规则）；
    /// iPad 分栏与右侧面板里设置在侧栏。
    private var page: some View {
        chat
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaPadding(.top, CueHeader.reserve)
            .overlay(alignment: .top) { CueHeader(showsSettings: !inPanel && navigation.layout == .tabs) }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                bottom
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .frame(maxWidth: Self.readingWidth)
                    .frame(maxWidth: .infinity)
                    .environment(\.composerInk, .solid)
            }
            .navigationTitle(cue.name)
            .toolbar(removing: .title)
            .toolbarVisibility(navigation.layout == .tabs ? .hidden : .automatic, for: .navigationBar)
    }
    #endif

    // MARK: 对话

    /// 读不出来时也排一个真的视图：读库的订阅挂在页上，等视图出现才启动（docs/ui.md）。
    @ViewBuilder private var chat: some View {
        Group {
            if let thread { conversation(thread) } else { Color.clear }
        }
    }

    private func conversation(_ thread: CueThread) -> some View {
        let rows = thread.rows
        return ChatColumn(
            followKey: FollowKey(thread, live: cue.presence.progress != nil), readingWidth: Self.readingWidth, inset: Self.inset, follow: $follow,
            marks: thread.marks, ids: rows.map(\.id), paging: Self.paging,
            holding: services.isCatchingUp(on: cue.hostID)
        ) { window, showEarlier in
            let first = max(0, rows.count - window)
            VStack(alignment: .leading, spacing: 0) {
                if first > 0 { EarlierRow(count: min(first, Self.paging.step), action: showEarlier) }
                let live = live
                let lastYou = thread.messages.last { $0.author == .known(.you) }?.id
                // 时间与那一格直接排进对话这一列，不另包一层：长对话滚动时每格少一个要摆的容器
                ForEach(rows[first...]) { item in
                    let joined = thread.joined.contains(item.id), stamp = thread.stamps[item.id]
                    if let stamp { ChatTimeMarker(date: stamp).padding(.top, 18) }
                    row(item, tasks: thread.tasks, lastYou: lastYou, live: live, joined: joined)
                        .padding(.top, stamp != nil ? 6 : Self.gap(before: item.speaker, joined: joined))
                }
                CueEnding(newestSaid: thread.messages.last { $0.author == .known(.cue) }?.createdAt, joined: rows.last?.speaker == .leading)
            }
            #if os(iOS)
            // 手机上对话里的字不开行内选择：长按出的是消息菜单，挑字走菜单里的"选择文本"（同会话页）
            .environment(\.inlineTextSelection, false)
            #endif
            // 刻度滑条按 id 跳到某一格（`ChatFollow.jump`）：滚动区只认滚动目标布局里的行
            .scrollTargetLayout()
            .animation(Motion.quick, value: cue.presence.progress)
        }
    }

    /// 在跑的那一轮（Cue 此刻的状态记着是哪一行）此刻的结尾；不在跑为 nil。
    private var live: CueLiveRound? {
        let presence = cue.presence
        guard let round = cue.round, let shown = presence.shown, let progress = presence.progress else { return nil }
        return CueLiveRound(round: round, ending: .live(shown, doing: progress, step: presence.isUsingTool ? RoundProcess.icon(.other) : nil))
    }

    /// 一格上面空多少：同一边连着说的收成一串，你开始说的新一轮与上一轮拉开，其余（Cue 接你的话、经过、动态、分隔）是一般的间距。
    /// `speaker`：这一格是谁的气泡（`CueThread.Row.speaker`），不是气泡为 nil。
    static func gap(before speaker: HorizontalEdge?, joined: Bool) -> CGFloat {
        if joined { return Bubble.joinedGap }
        return speaker == .trailing ? 22 : 12
    }

    /// `lastYou`：你最后一句，只在它下面写"已送达"。`live` 只交给它所在的那一格，别的格子输入不变、不随 Cue 的状态重算。
    @ViewBuilder private func row(_ row: CueThread.Row, tasks: [UUID: CueTaskRef], lastYou: UUID?, live: CueLiveRound?, joined: Bool) -> some View {
        switch row {
        case .you(let message):
            SpeechBubble(said: .cue(message, host: cue.hostID), box: Bindable(cue).draft, showsDelivered: message.id == lastYou, joined: joined) { _ in
                MessageActions(text: message.text, kind: .cue)
            }
        case .cue(let message, let task):
            CueSays(message: message, task: task.flatMap { tasks[$0] }, joined: joined, arrives: !swapsInPlace)
        case .notes(let notes):
            CueNotes(notes: notes, live: live.flatMap { live in notes.contains { $0.id == live.round } ? live : nil })
                .padding(.leading, Bubble.noteInset)
        case .process(let message):
            RoundProcess(tools: message.tools, ending: CueLiveRound.ending(of: message, in: live))
                .padding(.leading, Bubble.noteInset)
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

    private var bottom: some View {
        VStack(spacing: 8) {
            if let thread {
                CueWaitingDock(waiting: thread.waiting, tasks: thread.tasks) { opened = PreviewOpening(preview: $0) }
            }
            if !cue.canHear {
                CueEnableCard().transition(.opacity)
            }
            #if os(iOS)
            CueComposer(style: .page, focusRequests: inPanel ? 0 : navigation.cueFocusRequests) { follow.sent() }
            #else
            CueComposer(style: .page) { follow.sent() }
            #endif
        }
        .animation(Motion.quick, value: thread?.waiting.map(\.id))
        .animation(Motion.quick, value: cue.canHear)
    }
}

/// Cue 在跑的那一轮：经过那一行（`round`）此刻的结尾，其余经过不记用时。
/// 交给对话里各格的是这个值而不是闭包：闭包每次都不相等，Cue 的状态一变（被叫醒、在想→用工具）对话里每一格都要重算。
struct CueLiveRound: Equatable {
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
