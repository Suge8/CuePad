import CueStore
import SwiftUI

/// Cue 页（Mac 内容区的一页、iPhone 与 iPad 侧栏最上面那一行点进的页、iPad 右侧面板；iPhone 打开 App 就在这一页），与会话页同一套消息版式：
/// 页头一直在（头像、名字、此刻在做什么；Mac 在窗口工具栏，是 `CueTitle`；手机与 iPad 是浮在对话上的 `CueHeader`，点开是在做、等你与记忆的面板）；
/// 中间是对话：你的话是右侧牛皮纸色的气泡，Cue 的话是左侧纸做的气泡（`CueBubble`、`CueSays`），它第一次提到一件活时气泡底下一行这件活（`CueTaskLine`），
/// 同一边连着说的几颗收紧成一串，隔了一阵的地方居中写几点（`ChatTimeMarker`）；经过、醒来记录与分隔不是气泡，是旁注与居中的标记（`NoteLine`、`ChatMarker`），
/// 你发起的一轮在你的话之后先是这一轮的经过（`CueTrace`：碰到的任务与会话一处一行，在跑时原地往下长），这一轮说的话与结果按先后在它之后。
/// Cue 自己醒来的那几轮每轮一行旁注（`CueNoteLog`：提到的那一处、当时出了什么事与它说的一句，点了去那里），
/// 末尾是它此刻在做什么（`CueEnding`）；
/// 对话区与会话页是同一个（`ChatColumn`：排开、刻度滑条、跳转与描圈）；底部是拍板卡（`CueWaitDock`：Cue 的提问与会话在问的都在这里，
/// 对话里不另挂）与输入框（`CueComposer`），待回复提示（`CueReplyTip`）叠在它们上方。
/// 首次见面与启用只有一处（`CueWelcome`）：还没说过话时在正中，说过话后停用了在输入框正上方。
/// 对话第一帧就排好（`observing` 当场读），停在最新处；有新消息时从第一条读起，还没读的气泡旁一颗小点（`CueViewing`）。
/// Cue 运行在别的设备上、本机正在和 iCloud 对时（`AppServices.isCatchingUp(on:)`）页头写"正在同步"，这期间到的话先不滑上来，
/// 对完一次滑上来（`ChatColumn` 的 `holding`）：对完才算开始看，有新消息就到第一条新消息、从它读起，没有才到最新处（`CueViewing`）。
/// Cue 在做的事在任务与 Agent 页里看，这里不另列。
/// 页面只读写库：写一条你的消息就是对 Cue 说话，Cue 运行在哪台 Mac 都一样。"Cue 记得什么"（`CueMemoryPage`）在 Mac 的"⋯"里、手机页头的面板里；
/// Cue 在这台 Mac 值班时 Mac 的"⋯"里还有"运行情况"，在右侧开一栏（`CueRunPanel`）。
struct CuePage: View {
    /// iPad 右侧面板里：没有自己的顶栏（页头浮在面板顶上）。
    var inPanel = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 底部那一排换形时，输入框与 Cue 钮交叉（`DockHandoff`）；输入框有焦点时不给"⋯"让位置，焦点进出写在它上面（`PagerMotion.composing`）。
    @Environment(\.dockMotion) private var dockMotion
    #endif
    @State private var thread: CueThread?
    @State private var follow = ChatFollow()
    @State private var opened: PreviewOpening?
    /// 拍板卡正在来去（`CueWaitDock.moving`）：对话先不往上滑。
    @State private var docking = false
    /// 末尾在屏上的新消息（`CueViewing`）。
    @State private var seen: [UUID: Date] = [:]

    #if os(macOS)
    static let readingWidth: CGFloat = 760
    static let inset: CGFloat = 24
    /// 拍板卡与输入框离页底。
    static let replyPadding: CGFloat = 16
    #else
    static let readingWidth: CGFloat = 640
    static let inset: CGFloat = 16
    #endif

    private var cue: CueWatch { workspace.cue }
    private var catchingUp: Bool { services.isCatchingUp(on: cue.hostID) }
    var body: some View {
        page
            .observing(services.store, into: $thread, onError: workspace.fail) { try CueThread.read(from: $0) }
            .previewPresenter($opened, reply: .cue)
            .panel(isPresented: Bindable(cue).showsMemory) { CueMemoryPage() }
            .modifier(CueViewing(thread: thread, catchingUp: catchingUp, seen: $seen, follow: $follow))
            .onChange(of: thread != nil, initial: true) { _, loaded in
                guard loaded else { return }
                DebugHooks.mark("cue")
            }
    }

    // MARK: 平台

    #if os(macOS)
    private var page: some View {
        HStack(spacing: 0) {
            FloatingReply(gap: Self.replyPadding) {
                chat
            } reply: {
                bottom
                    .padding(.horizontal, Self.inset)
                    .frame(maxWidth: Self.readingWidth)
            }
            if cue.showsRun, let keeper = services.cue.keeper {
                CueRunPanel(keeper: keeper)
                    .padding([.trailing, .bottom], 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: cue.showsRun)
        .background(palette.desk)
    }
    #else
    /// 页顶那一排只有 Cue 的名牌（`CueHeader`，经 `floatingHeader`），浮在对话上，对话让出固定的一段：名牌展开成面板时对话不重排。窄屏上 Cue 页是导航栈的根、不需要返回，不用系统导航栏（`DockRoot`），
    /// 名牌就是最上面那一排；底部左边那颗"⋯"是底部那一排（`DockBar`，不在这一页里）收起的样子，这里给它让出位置，右边是输入框。
    /// 拍板卡与输入框浮在对话底上（`FloatingReply`，同会话页与 Mac，键盘也在那里让）；窄屏底部那一排没有键盘时离屏幕底边同 Dock。
    private var page: some View {
        FloatingReply(backed: false, floor: docked ? Dock.margin : nil) {
            chat
        } reply: {
            bottom
                .padding(.horizontal, docked ? Dock.margin : 12)
                .frame(maxWidth: Self.readingWidth)
        }
            .scrollDismissesKeyboard(.interactively)
            .floatingHeader(.verbatim(cue.name), height: CueHeader.height, center: { CueHeader() }) { EmptyView() }
    }

    /// 窄屏导航栈的根（不是 iPad 右侧面板）：底部是"⋯"加输入框。
    private var docked: Bool { !inPanel && sizeClass == .compact }

    /// 窄屏底部那一排：左边给"⋯"让出位置（输入框有焦点时不让），右边输入框；换形时与 Cue 钮交叉（`DockHandoff`）。
    private var dockRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if dockMotion?.composing != true {
                Color.clear.frame(width: Dock.slot + Dock.gap, height: Dock.slot)
            }
            composer.dockedComposer(dockMotion)
        }
    }
    #endif

    #if os(iOS)
    private var composer: some View {
        CueComposer(style: .page, takesFocusRequests: !inPanel, sent: { follow.sent() }) { focused in
            // 同底部那一排让开"⋯"的那条弹簧（`DockBar`）：输入框长宽与"⋯"淡出是同一下
            withAnimation(Motion.spatial(Motion.dock, reduceMotion: reduceMotion)) { dockMotion?.composing = focused }
        }
    }
    #endif

    // MARK: 对话

    /// 读不出来时也排一个真的视图：读库的订阅挂在页上，等视图出现才启动（docs/ui.md）。
    /// 还没说过话时正中是首次见面（`CueWelcome`：自我介绍，没启用时连同启用那一步，启用了接几句能直接说的话）。
    @ViewBuilder private var chat: some View {
        Group {
            if let thread, !thread.rows.isEmpty {
                conversation(thread)
            } else if thread != nil {
                CueWelcome(intro: true)
                    .padding(.horizontal, Self.inset)
                    .frame(maxWidth: Self.readingWidth, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
            } else {
                Color.clear
            }
        }
    }

    /// 只排开铺满可见区要的那几格（`paging`）：打开时铺一屏，离最早那头不到一屏时（打开后紧接着就是）往上再铺一屏；
    /// 约 `segment` 格一段地排，离屏远的段换成同高的空白（`ChatSegments`），发出一句时只重排最新那段。一格多高要排出来才知道，
    /// 这里按每格至少多高（`floor`）往上数：数到的只会多不会少，第一帧就铺满、不露空白（不估真实的高：估高了就排少了，
    /// 打开时接着一段段地补，按字数估的高在真实库上排少了、更慢）。
    private func conversation(_ thread: CueThread) -> some View {
        let rows = thread.rows
        return ChatColumn(
            followKey: FollowKey(thread, live: cue.presence.progress != nil), readingWidth: Self.readingWidth, inset: Self.inset, follow: $follow,
            marks: thread.marks, ids: rows.map(\.id), paging: Self.paging(thread),
            holding: catchingUp || docking,
            arrival: rows.last.flatMap { CueRow.arrives($0, swapsInPlace: services.cueSwapsInPlace) ? $0.id : nil }
        ) { window in
            let lastYou = thread.messages.last { $0.author == .known(.you) }?.id
            ChatStack(spacing: 0) {
                let live = live
                ChatSegments(items: rows, window: window, size: Self.segment, spare: Self.spare) { items in
                    CueSegment(rows: items.map { item in
                        CueRow(
                            row: item, shots: thread.shots[item.id] ?? [],
                            joined: thread.joined.contains(item.id),
                            stamp: thread.stamps[item.id], delivered: item.id == lastYou, live: live.flatMap { item.contains(round: $0.round) ? $0 : nil },
                            unread: thread.unread.contains(item.id), opened: $opened, seen: $seen)
                    })
                    .equatable()
                }
                CueEnding(
                    newestSaid: thread.messages.last { $0.author == .known(.cue) }?.createdAt, joined: rows.last?.speaker == .leading,
                    roundInRows: live.map { live in rows.contains { $0.contains(round: live.round) } } ?? false)
            }
            #if os(iOS)
            // 手机上对话里的字不开行内选择：长按出的是消息菜单，挑字走菜单里的"选择文本"（同会话页）
            .environment(\.inlineTextSelection, false)
            #endif
            .animation(HandOff.quick, value: cue.presence.progress)
        }
    }

    /// 在跑的那一轮（Cue 此刻的状态记着是哪一行，"做完了没"只看它）此刻的结尾；不在跑为 nil。它那台 Mac 此刻不在（`CuePresence.shown` 为空）时
    /// 这一轮照样没做完，只是不写在做什么。
    private var live: CueLiveRound? {
        let presence = cue.presence
        guard let round = cue.round else { return nil }
        guard let shown = presence.shown, let progress = presence.progress else { return CueLiveRound(round: round, doing: nil) }
        let step = presence.step
        // 没碰哪一处的一步（看板、记忆、读文件）是工具图标，还没调工具（在想）是省略号
        let icon = step.map { CueTrace.icon($0.kind) } ?? (presence.isUsingTool ? Icon.tool : .pondering)
        return CueLiveRound(round: round, doing: .init(icon: icon, step: step, text: progress, speaking: shown.speaking))
    }

    /// 有新内容：多了消息、有一条被答了、拍板或待回复变了、末尾的进展出现或收起。
    private struct FollowKey: Equatable {
        var count: Int
        var last: Date?
        var waiting: Int
        var replies: Int
        var live: Bool

        init(_ thread: CueThread, live: Bool) {
            count = thread.messages.count
            last = thread.messages.last?.modifiedAt
            waiting = thread.waiting.count
            replies = thread.replies.count
            self.live = live
        }
    }

    // MARK: 底部

    /// 浮在对话底上的一块：拍板卡、停用时的启用与输入框。输入框按自己的高、不被挤（`fixedSize`），地方不够时（键盘弹出、小屏、横屏、输入框写了好几行）卡用剩下的。
    /// 待回复提示叠在这一块上方、不占排版（`floatingAbove`）：它一出一收不改这一块的高，对话不跟着跳。
    private var bottom: some View {
        VStack(spacing: 0) {
            if let thread {
                CueWaitDock(waiting: thread.waiting, asking: workspace.cueAsking, shots: thread.shots, open: { opened = $0 }, moving: $docking)
                // 说过话后停用了：启用就在输入框正上方（`CueWelcome`），是这时唯一的主动作
                if !thread.rows.isEmpty, !cue.canHear { CueWelcome(intro: false).fixedSize(horizontal: false, vertical: true).padding(.bottom, ComposerMetrics.stackGap).transition(.opacity) }
            }
            #if os(iOS)
            Group { if docked { dockRow } else { composer } }.fixedSize(horizontal: false, vertical: true)
            #else
            CueComposer(style: .page, takesFocusRequests: true) { follow.sent() }.fixedSize(horizontal: false, vertical: true)
            #endif
        }
        .floatingAbove {
            if let replies = thread?.replies, !replies.isEmpty { CueReplyTip(replies: replies).transition(.opacity) }
        }
        .animation(HandOff.quick, value: cue.canHear)
        .animation(HandOff.quick, value: thread?.replies.isEmpty)
    }
}
