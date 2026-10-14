import CueStore
import SwiftUI

/// Cue 页（Mac 内容区的一页、iPhone Agent 标签的第一屏、iPad 侧栏最上面与右侧面板），与会话页同一套消息版式：
/// 最上面是页头（大头像、名字、此刻在做什么），离开期间有变化时下面一张"你不在时"（`CueAwayCard`）；
/// 中间是对话：你的话是右侧气泡，Cue 的话左侧全宽，它第一次提到一件活时下面一行这件活（`CueTaskLine`），
/// 连着的动态折成一行灰字（`CueNotes`）；底部从上到下是跟进中的托盘（`CueTray`）、"等你"（`CueWaitingDock`）与输入框（`CueComposer`）。
/// 页面只读写库：写一条你的消息就是对 Cue 说话，Cue 住在哪台 Mac 都一样。"⋯"里是"Cue 记得什么"（`CueMemoryPage`）。
struct CuePage: View {
    /// iPad 右侧面板里：没有自己的顶栏，"会话"换到侧栏的 Agent 页。
    var inPanel = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    @Environment(\.tabPageReady) private var tabPageReady
    #endif
    @State private var thread: CueThread?
    @State private var away: CueAway?
    @State private var follow = ChatFollow()
    @State private var window = Self.firstWindow
    @State private var opened: PiPreview?

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
    /// 头像露"在听"：输入框里有没说出去的话。
    private var composing: Bool { !cue.draft.isEmpty(accepting: .images) }

    var body: some View {
        page
            .observing(services.store, into: $thread, onError: workspace.fail) { try CueThread.read(from: $0) }
            .task(id: active) { if active { await loadAway() } else { markSeen() } }
            .onDisappear(perform: markSeen)
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
        VStack(spacing: 0) {
            chat.fadesUnderBars().frame(maxHeight: .infinity)
            bottom
                .padding(.horizontal, Self.inset).padding(.bottom, 16)
                .frame(maxWidth: Self.readingWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk)
    }
    #else
    @ViewBuilder private var page: some View {
        let body = chat
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
            body
        } else {
            body.floatingHeader(cue.name, detail: Dotted(cue.presence.line(name: cue.name) ?? "")) { trailing }
        }
    }

    /// 右上角：会话列表是常用入口，单独一颗圆钮（角标是在跑的会话数）；"⋯"里只留次要的（记忆）。
    private var trailing: some View {
        HStack(spacing: 4) {
            SessionsButton { navigation.push(.agent) }
            Menu {
                Button("\(cue.name) 记得什么", systemImage: "brain") { cue.showsMemory = true }
            } label: {
                Image(systemName: "ellipsis")
            }
            .accessibilityLabel("更多")
        }
    }
    #endif

    // MARK: 对话

    private var chat: some View {
        let thread = thread
        let rows = thread?.rows ?? []
        let first = max(0, rows.count - window)
        return ChatScroll(followKey: FollowKey(thread), readingWidth: Self.readingWidth, inset: Self.inset, follow: $follow) {
            VStack(alignment: .leading, spacing: PiConversation.spacing) {
                if first == 0 { CueHead(composing: composing) }
                if let away, !away.isEmpty {
                    CueAwayCard(away: away) { withAnimation(Motion.quick) { self.away = nil } }
                }
                if first > 0 { EarlierRow(hidden: first, action: showEarlier) }
                let lastYou = thread?.messages.last { $0.author == .known(.you) }?.id
                ForEach(rows[first...]) { item in row(item, tasks: thread?.tasks ?? [:], lastYou: lastYou) }
            }
        }
        .onChange(of: follow.nearOldest) { _, near in if near { showEarlier() } }
    }

    /// `lastYou`：你最后一句，只在它下面写"已送达"。
    @ViewBuilder private func row(_ row: CueThread.Row, tasks: [UUID: CueTaskRef], lastYou: UUID?) -> some View {
        switch row {
        case .you(let message):
            SpeechBubble(said: .cue(message, host: cue.digest.hostID), box: Bindable(cue).draft, showsDelivered: message.id == lastYou)
                .padding(.top, 14)
        case .cue(let message, let task):
            VStack(alignment: .leading, spacing: 6) {
                CueSays(message: message)
                if let task, let ref = tasks[task] { CueTaskLine(ref: ref) }
            }
        case .notes(let notes):
            CueNotes(notes: notes)
        }
    }

    private func showEarlier() {
        guard window < (thread?.rows.count ?? 0) else { return }
        follow.willPrepend()
        window += Self.firstWindow
    }

    /// 有新内容：多了消息、有一条被答了、派出的活变了。
    private struct FollowKey: Equatable {
        var count: Int
        var last: Date?
        var waiting: Int

        init(_ thread: CueThread?) {
            count = thread?.messages.count ?? 0
            last = thread?.messages.last?.modifiedAt
            waiting = thread?.waiting.count ?? 0
        }
    }

    // MARK: 底部

    private var bottom: some View {
        VStack(spacing: 8) {
            if let thread {
                CueTray(board: thread.board, startsCollapsed: !thread.waiting.isEmpty) { opened = $0 }
                CueWaitingDock(waiting: thread.waiting, tasks: thread.tasks) { opened = $0 }
            }
            if cue.presence == .disabled {
                CueEnableCard().transition(.opacity)
            } else if cue.presence.isAway {
                // 页头翻出屏幕之后，输入框上方仍看得到它为什么不接话
                CueStatusLine().frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18)
            }
            CueComposer(style: .page) { follow.jumpToNewest() }
        }
        .animation(Motion.quick, value: thread?.waiting.map(\.id))
        .animation(Motion.quick, value: thread?.board.map(\.id))
        .animation(Motion.quick, value: cue.presence)
    }

    // MARK: 你不在时

    private func loadAway() async {
        guard let since = services.settings.cueSeenAt else { return markSeen() }
        do {
            let found = try await CueAway.read(since: since, from: services.store)
            withAnimation(Motion.quick) { away = found.isEmpty ? nil : found }
        } catch {
            workspace.fail(error)
        }
    }

    private func markSeen() { services.settings.cueSeenAt = .now }
}

#if os(iOS)
/// Cue 页顶栏的会话钮：图标右上一个墨色小角标写在跑的会话数（没有在跑的不画；墨色不是注意色：在跑不用你管）。
private struct SessionsButton: View {
    let action: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption2) private var size: CGFloat = 9
    @ScaledMetric(relativeTo: .caption2) private var diameter: CGFloat = 15

    var body: some View {
        let running = services.liveSessions.live.count { $0.state.isWorking }
        Button(action: action) {
            Image(systemName: "rectangle.stack")
                .overlay(alignment: .topTrailing) {
                    if running > 0 {
                        Text("\(running)").font(.system(size: size, weight: .bold).monospacedDigit()).foregroundStyle(palette.paper)
                            .padding(.horizontal, 3).frame(minWidth: diameter, minHeight: diameter)
                            .background(palette.ink, in: .capsule)
                            .offset(x: diameter * 0.6, y: -diameter * 0.45)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.quick, value: running)
        }
        .accessibilityLabel("会话")
        .accessibilityValue(running > 0 ? "\(running) 个在跑" : "")
    }
}
#endif

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
