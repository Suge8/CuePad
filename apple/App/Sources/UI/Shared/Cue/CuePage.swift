import CueStore
import CueText
import SwiftUI
#if os(macOS)
import CuePi
#endif

/// Cue 页（Mac 内容区的一页、iPhone 与 iPad 侧栏最上面那一行点进的页、iPad 右侧面板；iPhone 打开 App 就在这一页），与会话页同一套消息版式：
/// 页头一直在（头像、名字、此刻在做什么；Mac 在窗口工具栏，是 `CueTitle`；手机与 iPad 是浮在对话上的 `CueHeader`，点开是在做、等你与记忆的面板）；
/// 中间是对话：你的话是右侧牛皮纸色的气泡，Cue 的话是左侧纸做的气泡（`CueBubble`、`CueSays`），它第一次提到一件活时气泡底下一行这件活（`CueTaskLine`），
/// 同一边连着说的几颗收紧成一串，隔了一阵的地方居中写几点（`ChatTimeMarker`）；经过、动态与分隔不是气泡，是旁注与居中的标记（`NoteLine`、`ChatMarker`），
/// 你发起的一轮在你的话之后先是这一轮的经过（`RoundProcess`，同会话页：在跑时实时展开，做完收成一行；设置里可关，`AppSettings.showsCueSteps`），这一轮说的话与结果按先后在它之后；
/// 经过清单里"对你说"那一条点它回到对话里的原处。Cue 自己醒来的连着几轮收进一颗虚线气泡（`CueNoteBubble`：每轮写为什么醒，点了去叫醒它的会话），
/// 它换了新上下文的地方一条分隔（`CueRenewal`，点开是交接备忘），末尾是它此刻在做什么（`CueEnding`）；
/// 对话区与会话页是同一个（`ChatColumn`：排开、刻度滑条、跳转与描圈）；底部是"等你"（`CueWaitingDock`）与输入框（`CueComposer`）。
/// 对话第一帧就排好（`observing` 当场读），停在最新处；有新消息时从第一条读起，还没读的气泡旁一颗小点（`CueViewing`）。
/// Cue 运行在别的设备上、本机正在和 iCloud 对时（`AppServices.isCatchingUp(on:)`）页头写"正在同步"，这期间到的话先不滑上来，
/// 对完一次滑到最新（`ChatColumn` 的 `holding`）。
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
    @Environment(Navigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// 这一页的输入框占着底边，底部那一排的 Cue 钮把位置交给它（`DockRoot`）。
    @Environment(\.dockComposer) private var ownsComposer
    #endif
    @State private var thread: CueThread?
    @State private var follow = ChatFollow()
    @State private var opened: PreviewOpening?
    /// 对话那一列的宽：离屏远的段换成的空白按它估高（`ChatSegments`）。
    @State private var width: CGFloat = 0
    /// "等你"卡正在来去（`CueWaitingDock.moving`）：对话先不往上滑。
    @State private var docking = false
    /// 末尾在屏上的新消息（`CueViewing`）。
    @State private var seen: [UUID: Date] = [:]

    #if os(macOS)
    static let readingWidth: CGFloat = 760
    static let inset: CGFloat = 24
    /// "等你"卡与输入框离页底。
    static let replyPadding: CGFloat = 16
    #else
    static let readingWidth: CGFloat = 640
    static let inset: CGFloat = 16
    #endif

    private var cue: CueWatch { workspace.cue }
    private var catchingUp: Bool { services.isCatchingUp(on: cue.hostID) }
    private var showsSteps: Bool { services.settings.showsCueSteps }

    var body: some View {
        page
            .observing(services.store, id: showsSteps, into: $thread, onError: workspace.fail) { [showsSteps] in
                try CueThread.read(from: $0, showsSteps: showsSteps)
            }
            .previewPresenter($opened)
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
            FloatingReply {
                chat
            } reply: {
                bottom
                    .padding(.horizontal, Self.inset).padding(.bottom, Self.replyPadding)
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
    /// 页头浮在对话上（`CueHeader`），对话让出固定的一段：页头展开成面板时对话不重排。窄屏上 Cue 页是导航栈的根、不需要返回，不用系统导航栏（`DockRoot`），
    /// 页头就是最上面那一排；底部左边那颗"⋯"是底部那一排（`DockBar`，不在这一页里）收起的样子，这里给它让出位置，右边是输入框。
    /// "等你"卡与输入框浮在对话底上（`FloatingReply`，同 Mac；在键盘之上）：不做成底下那一栏（安全区）——栏一变矮（发出时输入框收回一行、
    /// 卡沉下去）可见区当帧变高、系统把对话一下拉下去，发出的话一两帧后才到、再滑上来；栏一变高（卡升起）系统当帧挪、滚动区下一帧才跟上。
    /// 键盘只经系统的安全区让：输入框有焦点时贴着安全区底边（有键盘就是键盘顶，第三方键盘长高、换键盘、下拖收起都由系统跟），
    /// 窄屏没焦点时整块伸到屏幕底、底部那一排离屏幕底边同 Dock。不读键盘高：导航栈里的页拿到的键盘是普通安全区，
    /// `.ignoresSafeArea(.keyboard)` 分不出来，拿它量"没有键盘的底"在键盘弹出时量到的是键盘高，那一排被压回键盘底下。
    private var page: some View {
        let toScreen = docked && !navigation.cueComposing
        return FloatingReply(backed: false) {
            chat.overlay { if docked, navigation.placesOpen { closePlaces } }
        } reply: {
            bottom
                .padding(.horizontal, docked ? Dock.margin : 12)
                .padding(.bottom, toScreen ? Dock.margin : Dock.keyboardGap)
                .frame(maxWidth: Self.readingWidth)
        }
            .ignoresSafeArea(edges: toScreen ? .bottom : [])
            .scrollDismissesKeyboard(.interactively)
            .safeAreaPadding(.top, CueHeader.reserve)
            .overlay(alignment: .top) { CueHeader(underBanner: docked) }
            .navigationTitle(cue.name)
            // 标题只给读屏与系统：名字在页头里
            .toolbar(removing: .title)
    }

    /// 窄屏导航栈的根（不是 iPad 右侧面板）：底部是"⋯"加输入框。
    private var docked: Bool { !inPanel && sizeClass == .compact }

    /// "⋯"展开时铺在对话上的一层：点一下或一划就收起。
    private var closePlaces: some View {
        Color.clear.contentShape(.rect)
            .onTapGesture { navigation.placesOpen = false }
            .gesture(DragGesture(minimumDistance: 4).onChanged { _ in navigation.placesOpen = false })
            .accessibilityHidden(true)
    }

    /// 窄屏底部那一排：左边给"⋯"让出位置（输入框有焦点时不让），右边输入框。"⋯"展开着、换来这一页时 Cue 钮还在长成它，
    /// 输入框的位置是底部那一排的 Cue 钮，这里的输入框藏着；长到了才接手（`DockRoot.handed`），离开时当场藏起。
    private var dockRow: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if !navigation.cueComposing {
                Color.clear.frame(width: Dock.slot + Dock.gap, height: Dock.slot)
            }
            composer
                .opacity(ownsComposer ? 1 : 0)
                .allowsHitTesting(ownsComposer)
                .accessibilityHidden(!ownsComposer)
        }
    }
    #endif

    #if os(iOS)
    private var composer: some View {
        CueComposer(style: .page, focusRequests: inPanel ? 0 : navigation.cueFocusRequests, sent: { follow.sent() }) { focused in
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { navigation.cueComposing = focused }
        }
    }
    #endif

    // MARK: 对话

    /// 读不出来时也排一个真的视图：读库的订阅挂在页上，等视图出现才启动（docs/ui.md）。
    /// 还没说过话时是空态（`EmptyState`）：它自我介绍，下一步就是下面的输入框（没启用时是启用卡，说清启用后活放进默认项目）。
    @ViewBuilder private var chat: some View {
        Group {
            if let thread, !thread.rows.isEmpty {
                conversation(thread)
            } else if thread != nil {
                EmptyState(mascot: .hello, title: "我是 \(cue.name)", message: greeting, waitsForSync: true)
                    .padding(.horizontal, Self.inset)
                    .frame(maxWidth: Self.readingWidth, maxHeight: .infinity)
                    .frame(maxWidth: .infinity)
            } else {
                Color.clear
            }
        }
    }

    /// 空态的那句：启用了就请他直接说；没启用时说启用后怎么用（说一件事，它放进默认项目里开工），启用卡只放启用那一步。
    private var greeting: String {
        guard !cue.canHear else { return "要做什么，直接在下面跟我说" }
        let home = workspace.catalog?.project(Project.defaultID)?.name ?? ""
        return "启用后说一件想做的事，我放进「\(home)」项目里开工，只在要你拿主意时找你"
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
            holding: catchingUp || docking
        ) { window in
            let first = max(0, rows.count - window.count)
            let lastYou = thread.messages.last { $0.author == .known(.you) }?.id
            VStack(alignment: .leading, spacing: 0) {
                if first > 0 { EarlierRow(count: window.earlier, action: window.showEarlier) }
                let live = live
                ChatSegments(
                    items: rows, size: Self.segment, from: first, width: width, spare: Self.spare
                ) { items in
                    CueSegment(rows: items.map { item in
                        CueRow(
                            row: item, ref: item.taskID.flatMap { thread.tasks[$0] }, shots: thread.shots[item.id] ?? [],
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
            // 滚动目标（段与其余各行）：内容变了滚动位置跟着它走（`ChatScroll`）；跳到某一条按条的 id 找，不靠它
            .scrollTargetLayout()
            .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
            .animation(Motion.quick, value: cue.presence.progress)
        }
    }

    /// 在跑的那一轮（Cue 此刻的状态记着是哪一行，"做完了没"只看它）此刻的结尾；不在跑为 nil。它那台 Mac 此刻不在（`CuePresence.shown` 为空）时
    /// 这一轮照样没做完，只是不写在做什么。
    private var live: CueLiveRound? {
        let presence = cue.presence
        guard let round = cue.round else { return nil }
        guard let shown = presence.shown, let progress = presence.progress else { return CueLiveRound(round: round, ending: .took(nil)) }
        return CueLiveRound(round: round, ending: .live(shown, doing: progress, step: presence.isUsingTool ? RoundProcess.icon(.other) : nil))
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

    /// 浮在对话底上的一块："等你"卡、启用卡与输入框。输入框按自己的高、不被挤（`fixedSize`），地方不够时（键盘弹出、小屏、横屏、输入框写了好几行）卡用剩下的。
    private var bottom: some View {
        VStack(spacing: 0) {
            if let thread {
                CueWaitingDock(waiting: thread.waiting, tasks: thread.tasks, shots: thread.shots, open: { opened = $0 }, moving: $docking)
            }
            if !cue.canHear {
                CueEnableCard().padding(.bottom, 8).transition(.opacity)
            }
            #if os(iOS)
            Group { if docked { dockRow } else { composer } }.fixedSize(horizontal: false, vertical: true)
            #else
            CueComposer(style: .page) { follow.sent() }.fixedSize(horizontal: false, vertical: true)
            #endif
        }
        .animation(Motion.quick, value: cue.canHear)
    }
}
