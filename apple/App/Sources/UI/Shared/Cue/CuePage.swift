import CueStore
import SwiftUI
#if os(macOS)
import CuePi
#endif

/// Cue 页（Mac 内容区的一页、iPhone 的 Cue 标签、iPad 侧栏最上面与右侧面板），与会话页同一套消息版式：
/// 页头一直在（`CueTitle`：头像、名字、此刻在做什么；Mac 在窗口工具栏，手机在顶栏，iPad 面板在顶上）；
/// 中间是对话：你的话是右侧气泡，Cue 的话左侧全宽，它第一次提到一件活时下面一行这件活（`CueTaskLine`），
/// 连着的动态折成一行灰字（`CueNotes`），末尾是它此刻在做什么（`CueEnding`）；底部是"等你"（`CueWaitingDock`）与输入框（`CueComposer`）。
/// Cue 在做的事在任务与 Agent 页里看，这里不另列。
/// 页面只读写库：写一条你的消息就是对 Cue 说话，Cue 住在哪台 Mac 都一样。"⋯"里是"Cue 记得什么"（`CueMemoryPage`）；
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
    #endif
    @State private var thread: CueThread?
    @State private var follow = ChatFollow()
    @State private var window = Self.firstWindow
    @State private var opened: PreviewOpening?

    /// 最初排开最近几格，往上翻快到头时再排开一段（同 `SessionChat`）。
    private static let firstWindow = 40
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
            #if os(iOS)
            .onChange(of: thread != nil, initial: true) { _, loaded in if loaded { tabPageReady?() } }
            #endif
    }

    // MARK: 平台

    #if os(macOS)
    private var page: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                chat.modifier(BelowHeader()).frame(maxHeight: .infinity)
                bottom
                    .padding(.horizontal, Self.inset).padding(.bottom, 16)
                    .frame(maxWidth: Self.readingWidth)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if cue.showsRun, let keeper = services.cue.keeper {
                CueRunPanel(keeper: keeper, handoff: thread?.lastHandoff)
                    .padding([.trailing, .bottom], 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.panel, value: cue.showsRun)
        .background(palette.desk)
    }
    #else
    @ViewBuilder private var page: some View {
        let body = chat
            .modifier(BelowHeader())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .bottom, spacing: 0) {
                bottom
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .frame(maxWidth: Self.readingWidth)
                    .frame(maxWidth: .infinity)
                    .environment(\.composerInk, .solid)
            }
            // Cue 页在屏上（整页或 iPad 右侧面板）就由它显示提示（操作结果、别的会话做完了）：排在页头下面、占自己的位置，
            // 顶部的提示横幅这时不出现（`AppServices.cueViewers`）
            .safeAreaBar(edge: .top, spacing: 0) {
                if let notice = workspace.notice {
                    NoticeCapsule(notice: notice).padding(.horizontal, 16).padding(.top, 8)
                        .frame(maxWidth: Self.readingWidth)
                        .transition(.opacity)
                        .id(notice.id)
                }
            }
            .animation(Motion.quick, value: workspace.notice)
            .modifier(NoticeFeedback(notice: workspace.notice))
        if inPanel {
            body.safeAreaBar(edge: .top, spacing: 0) {
                CueTitle().frame(height: FloatingHeaderLayout.height).glass(in: .capsule, ink: .legible)
            }
        } else {
            body.floatingHeader(cue.name) { CueTitle() } trailing: { trailing }
        }
    }

    /// 右上角"⋯"：Cue 记得什么。会话在 Agent 标签里，这里不另放入口。
    private var trailing: some View {
        Menu {
            Button("\(cue.name) 记得什么", systemImage: "brain") { cue.showsMemory = true }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("更多")
    }
    #endif

    // MARK: 对话

    private var chat: some View {
        let thread = thread
        let rows = thread?.rows ?? []
        let first = max(0, rows.count - window)
        return ChatScroll(followKey: FollowKey(thread, live: cue.presence.progress != nil), readingWidth: Self.readingWidth, inset: Self.inset, follow: $follow) {
            VStack(alignment: .leading, spacing: PiConversation.spacing) {
                if first > 0 { EarlierRow(hidden: first, action: showEarlier) }
                ForEach(rows[first...]) { item in row(item, tasks: thread?.tasks ?? [:]) }
                CueEnding(newestSaid: thread?.messages.last { $0.author == .known(.cue) }?.createdAt)
            }
            .animation(Motion.quick, value: cue.presence.progress)
        }
        .onChange(of: follow.nearOldest) { _, near in if near { showEarlier() } }
    }

    @ViewBuilder private func row(_ row: CueThread.Row, tasks: [UUID: CueTaskRef]) -> some View {
        switch row {
        case .you(let message):
            UserBubble(stored: message.text).padding(.top, 14)
        case .cue(let message, let task):
            VStack(alignment: .leading, spacing: 6) {
                CueSays(message: message, fadesIn: !swapsInPlace)
                if let task, let ref = tasks[task] { CueTaskLine(ref: ref) }
            }
        case .notes(let notes):
            CueNotes(notes: notes)
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

    private func showEarlier() {
        guard window < (thread?.rows.count ?? 0) else { return }
        follow.willPrepend()
        window += Self.firstWindow
    }

    /// 有新内容：多了消息、有一条被答了、"等你"变了、末尾的进展出现或收起。
    private struct FollowKey: Equatable {
        var count: Int
        var last: Date?
        var waiting: Int
        var live: Bool

        init(_ thread: CueThread?, live: Bool) {
            count = thread?.messages.count ?? 0
            last = thread?.messages.last?.modifiedAt
            waiting = thread?.waiting.count ?? 0
            self.live = live
        }
    }

    // MARK: 底部

    private var bottom: some View {
        VStack(spacing: 8) {
            if let thread {
                CueWaitingDock(waiting: thread.waiting, tasks: thread.tasks) { opened = PreviewOpening(preview: $0) }
            }
            if cue.presence == .disabled {
                CueEnableCard().transition(.opacity)
            }
            CueComposer(style: .page) { follow.jumpToNewest() }
        }
        .animation(Motion.quick, value: thread?.waiting.map(\.id))
        .animation(Motion.quick, value: cue.presence == .disabled)
    }
}

/// Cue 页对话的末尾：它在做事时一行进展（`LiveLine`，同会话页）。Cue 在这台 Mac 值班时，在回答你的一轮出字就换成逐字长出的正在说的话
/// （`CueKeeper.speech`，同会话页的 `SessionDraft`）：只有这个视图读它，出字时对话列表不重算；它与对话在同一次更新里拿到同一份对话，
/// 落库了（`PiDraft.landed`）就不再显示，换下是同一帧里的一减一加。已落库而 Cue 的状态还没歇下时也不冒出进展那一行（话已经说完）；
/// 中途转成工具调用时让位给进展那一行。进展那一行被换下时直接拿掉，不与正在说的话叠着淡出。别的 Mac 与手机只有进展那一行。
private struct CueEnding: View {
    /// 对话里最近一条 Cue 的话的时刻
    let newestSaid: Date?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        #if os(macOS)
        let draft = services.cue.keeper?.speech.draft
        let landed = draft?.landed(newestReply: newestSaid) ?? false
        if let draft, !landed {
            DraftReply(text: draft.text) { EmptyView() }
        } else if !landed {
            live
        }
        #else
        live
        #endif
    }

    @ViewBuilder private var live: some View {
        let presence = workspace.cue.presence
        if let shown = presence.shown, let progress = presence.progress {
            LiveLine(shown: shown, text: progress).transition(.asymmetric(insertion: .entry, removal: .identity))
        }
    }
}

/// 对话从页头下面开始，不滚到它后面（Mac 是窗口工具栏，手机是名牌与它下面的提示）：名牌是一颗小胶囊、提示是一整条，
/// 气泡滚过去时两层字叠在一起读不清，也看不出提示后面还有没有话（别的沉浸式页照 `fadesUnderBars`）。
/// 上安全区里含页头与 safeAreaBar 里的提示：那一段全透，下沿往下 `Bars.contentGap` 淡回，滚出去的字不是一刀切断。
private struct BelowHeader: ViewModifier {
    func body(content: Content) -> some View {
        content.mask {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    Color.clear.frame(height: proxy.safeAreaInsets.top)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: Bars.contentGap)
                    Rectangle()
                }
                .ignoresSafeArea()
            }
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
