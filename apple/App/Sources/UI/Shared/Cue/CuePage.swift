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
    /// 输入框有焦点：左边的去处圆钮让开，输入框占满整排。
    @State private var composing = false
    /// 去处圆钮展开成了三格。
    @State private var placesOpen = false
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
    private static let readingWidth: CGFloat = 760
    private static let inset: CGFloat = 24
    /// "等你"卡与输入框离页底。
    private static let replyPadding: CGFloat = 16
    #else
    private static let readingWidth: CGFloat = 640
    private static let inset: CGFloat = 16
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
    /// 页头就是最上面那一排；底部是一排里左边那颗去处圆钮（`DockPlaces`）加输入框。
    /// "等你"卡与输入框浮在对话底上（`FloatingReply`，同 Mac；在键盘之上）：不做成底下那一栏（安全区）——栏一变矮（发出时输入框收回一行、
    /// 卡沉下去）可见区当帧变高、系统把对话一下拉下去，发出的话一两帧后才到、再滑上来；栏一变高（卡升起）系统当帧挪、滚动区下一帧才跟上。
    /// 键盘只经系统的安全区让：输入框有焦点时贴着安全区底边（有键盘就是键盘顶，第三方键盘长高、换键盘、下拖收起都由系统跟），
    /// 窄屏没焦点时整块伸到屏幕底、底部那一排离屏幕底边同 Dock。不读键盘高：导航栈里的页拿到的键盘是普通安全区，
    /// `.ignoresSafeArea(.keyboard)` 分不出来，拿它量"没有键盘的底"在键盘弹出时量到的是键盘高，那一排被压回键盘底下。
    private var page: some View {
        let toScreen = docked && !composing
        return FloatingReply(backed: false) {
            chat.overlay { if placesOpen { closePlaces } }
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

    /// 窄屏导航栈的根（不是 iPad 右侧面板）：底部是去处圆钮加输入框。
    private var docked: Bool { !inPanel && sizeClass == .compact }

    /// 去处圆钮展开时铺在对话上的一层：点一下或一划就收起。
    private var closePlaces: some View {
        Color.clear.contentShape(.rect)
            .onTapGesture(perform: collapsePlaces)
            .gesture(DragGesture(minimumDistance: 4).onChanged { _ in collapsePlaces() })
            .accessibilityHidden(true)
    }

    private func collapsePlaces() {
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { placesOpen = false }
    }

    /// 窄屏底部那一排：左边去处圆钮（输入框有焦点时让开），右边输入框；从三页来时从 Dock 的样子长过来。
    private var dockRow: some View {
        CueDockRow(
            placesOpen: $placesOpen, composing: composing,
            arrival: reduceMotion ? nil : Dock.Arrival(from: navigation.previousRoot, to: .cue)
        ) { composer }
            .debugExposesPlaces { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { placesOpen.toggle() } }
    }
    #endif

    #if os(iOS)
    private var composer: some View {
        CueComposer(style: .page, focusRequests: inPanel ? 0 : navigation.cueFocusRequests, sent: { follow.sent() }) { focused in
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { composing = focused }
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

    /// 一段约几格；屏上那几段上下各留几段真的（`ChatSegments`）。Cue 的回答长、一段要排几十毫秒（真实库），只留一段的话
    /// 来回翻几屏时每拆了又建一段就卡一下；留八段时翻动与整段都挂着一样顺，挂着的仍有上限。
    static let segment = 6, spare = 8

    /// 一格上面空多少：同一边连着说的收成一串，你开始说的新一轮与上一轮拉开，其余（Cue 接你的话、经过、动态、分隔）是一般的间距。
    /// `speaker`：这一格是谁的气泡（`CueThread.Row.speaker`），不是气泡为 nil。
    static func gap(before speaker: HorizontalEdge?, joined: Bool) -> CGFloat {
        if joined { return CueBubble.joinedGap }
        return speaker == .trailing ? 24 : 16
    }

    /// 隔了一阵写时间的那一格：时间上面空多少、时间与这一格之间空多少（`ChatTimeMarker`；排的与估高的同用这两个）。
    static let stampAbove: CGFloat = 16, stampBelow: CGFloat = 4

    /// 打开与往上翻都铺一屏（`conversation`），按每格至少多高（`floor`）从下往上数，只算数到的那几格；打开时最新处停在浮着的那一块上方，
    /// 只铺它上面那一截（`covered`）。
    private static func paging(_ thread: CueThread) -> ChatPaging {
        let rows = thread.rows
        func count(filling size: CGSize, above: Int) -> Int {
            // 阅读栏（可见区里去掉两边的边距，`ChatLayout.margin`）
            let column = min(size.width, readingWidth) - 2 * inset
            var sum: CGFloat = 0, count = 0
            for row in rows[..<above].reversed() where sum < size.height {
                sum += floor(row, shots: thread.shots[row.id]?.count ?? 0, joined: thread.joined.contains(row.id), stamped: thread.stamps[row.id] != nil, column: column)
                count += 1
            }
            return max(count, 1)
        }
        return ChatPaging(
            first: { count(filling: CGSize(width: $0.width, height: $0.height - covered(thread, size: $0)), above: $1) },
            step: { count(filling: $0, above: $1) })
    }

    /// 浮在对话底上的那一块（`bottom`）至少多高：对话底下让出它那么高的留白（`chatBottomInset`），最新处停在它上方。
    /// Mac 上按输入框（`ComposerMetrics`）、底下的边距与"等你"卡（`CueWaitingDock.floor`）的下限算，只能数少；
    /// 手机上没算这两样的下限，按整屏数（多排几格，不会铺不满）。
    private static func covered(_ thread: CueThread, size: CGSize) -> CGFloat {
        #if os(macOS)
        let composer = ComposerMetrics.textTop + ComposerMetrics.textBottomOpen + ComposerMetrics.slot
        // 卡与阅读栏同宽（`page` 里回复那一块两边让出同样的边距），至多占对话区的一半
        let floor = thread.waiting.first.map { CueWaitingDock.floor($0, shots: thread.shots, width: min(size.width, readingWidth) - 2 * inset) } ?? 0
        let dock = min(floor, size.height / 2)
        return composer + replyPadding + dock
        #else
        0
        #endif
    }

    /// 一格至少多高（连同上面的间距与时间）：气泡里的字至少多高（`TextFloor`），点名了图的提问与结果卡另有图（`shots` 张，`CueShots.floor`），
    /// 结果卡还有下面那件活一行，旁注、经过与分隔至少一行小字（`note`），动态的虚线气泡里至少一行。
    /// 只能数少、不能数多（数多了第一帧铺不满）；数得越贴，打开时多排的越少。
    private static func floor(_ row: CueThread.Row, shots: Int, joined: Bool, stamped: Bool, column: CGFloat) -> CGFloat {
        let note: CGFloat = 12
        let above = stamped ? stampAbove + note + stampBelow : gap(before: row.speaker, joined: joined)
        let bubble = CueBubble.padding.top + CueBubble.padding.bottom
        // 气泡里字排开的宽：气泡最宽占阅读栏的那一份，去掉内边距（`BubbleWidth`）
        func width(_ fraction: CGFloat) -> CGFloat { column * fraction - CueBubble.padding.leading - CueBubble.padding.trailing }
        func said(_ text: String) -> CGFloat {
            TextFloor.plain(CueFormat.plainText(text), width: width(UserBubble<EmptyView>.widthFraction), limit: UserBubble<EmptyView>.foldedLines)
        }
        func answer(_ text: String) -> CGFloat { TextFloor.markdown(text, width: width(CueBubble.cueWidth), spacing: Typography.readingLineSpacing) }
        let body: CGFloat = switch row {
        case .you(let message): bubble + said(message.text)
        // 引用那一行至少一行小字，下面是回答
        case .answer(let question): bubble + note + 6 + said(question.answer ?? "")
        // 字与图之间隔 8（`CueSays`）
        case .cue(let message, _): bubble + answer(message.text) + (shots == 0 ? 0 : 8 + CueShots.floor(count: shots, width: width(CueBubble.cueWidth)))
        // 字、图与那件活（至少 `CueTaskLine` 那么高）之间各隔 12
        case .result(let message, _):
            bubble + answer(message.text) + 12 + CueShots.floor(count: shots, width: width(CueBubble.cueWidth)) + 12 + CueTaskLine.lineHeight
        // 虚线气泡至少一行小字
        case .notes: bubble + note
        case .process, .renewed: note
        }
        return above + body
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

/// 对话里的一段（约 `CuePage.segment` 格，`ChatSegments`）：只按各格的内容比较。
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
    let shots: [CueShown]
    let joined: Bool
    let stamp: Date?
    /// 你最后一句：气泡旁标已送达（`BubbleTrip.delivered`）。
    let delivered: Bool
    let live: CueLiveRound?
    /// 这一格是新消息：左边一颗小点（`CueUnreadDot`），末尾进出滚动区时报给页面（`CueViewing`）。
    let unread: Bool
    @Binding var opened: PreviewOpening?
    @Binding var seen: [UUID: Date]
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    /// 这一格排出来什么样只看这几样。
    nonisolated struct Key: Equatable {
        let row: CueThread.Row, ref: CueTaskRef?, shots: [CueShown], joined: Bool, stamp: Date?, delivered: Bool, live: CueLiveRound?, unread: Bool
    }

    nonisolated var key: Key {
        Key(row: row, ref: ref, shots: shots, joined: joined, stamp: stamp, delivered: delivered, live: live, unread: unread)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }

    var body: some View {
        if let stamp { ChatTimeMarker(date: stamp).padding(.top, CuePage.stampAbove) }
        content
            .overlay(alignment: .topLeading) {
                CueUnreadDot(unread: unread).alignmentGuide(.leading) { $0[.trailing] + CueUnreadDot.gap }
            }
            .padding(.top, stamp != nil ? CuePage.stampBelow : CuePage.gap(before: row.speaker, joined: joined))
            .background(alignment: .bottom) {
                if unread {
                    CueEndProbe { visible in seen[row.id] = visible ? row.date : nil }
                }
            }
    }

    @ViewBuilder private var content: some View {
        let cue = workspace.cue
        switch row {
        case .you(let message):
            SpeechBubble(said: .cue(message, host: cue.hostID), box: Bindable(cue).draft, showsDelivered: delivered, look: .cue(joined: joined)) { _ in
                MessageActions(text: message.text, kind: .cue)
            }
        case .answer(let question):
            CueAnswer(question: question, joined: joined)
        case .cue(let message, _):
            CueSays(message: message, task: ref, shots: shots, open: { opened = $0 }, joined: joined, arrives: !swapsInPlace)
        case .result(let message, _):
            CueSays(message: message, task: ref, shots: shots, open: { opened = $0 }, card: true)
        case .notes(let rounds):
            CueNoteBubble(rounds: rounds, live: live)
        case .process(let message):
            RoundProcess(tools: message.tools, ending: CueLiveRound.ending(of: message, in: live)).padding(.leading, CueBubble.noteInset)
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

/// Cue 页对话的末尾：它在做事、这一轮在对话里还没有一格（你发起的一轮还没调过工具，或设置里关了工具步骤）时是一行此刻在做的（`RoundProcess` 的那一行，同会话页）。
/// Cue 在这台 Mac 值班时，在回答你的一轮出字就换成逐字长出的正在说的话
/// （`CueKeeper.speech`，同会话页的 `SessionDraft`）：只有这个视图读它，出字时对话列表不重算；它与对话在同一次更新里拿到同一份对话，
/// 落库了（`PiDraft.landed`）就不再显示，换下是同一帧里的一减一加。已落库而 Cue 的状态还没歇下时也不冒出进展那一行（话已经说完）；
/// 中途转成工具调用时让位给进展那一行。进展那一行被换下时直接拿掉，不与正在说的话叠着淡出。别的 Mac 与手机只有进展那一行。
private struct CueEnding: View {
    /// 对话里最近一条 Cue 的话的时刻
    let newestSaid: Date?
    /// 对话最后一格是 Cue 的话：正在说的这句落库后与它连成一串，说着的时候就排成那个样子。
    let joined: Bool
    /// 在跑的那一轮在对话里有一格（它的经过，或收着它的动态）：此刻在做的写在那一格里，这里不再写一遍。
    /// 没有那一格时（你发起的一轮还没调过工具；设置里关了工具步骤，`CueThread.rows` 不排经过）写在这里。
    let roundInRows: Bool
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
            BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
                MarkdownText(source: draft.text).equatable().cueBubble(joined: joined)
            }
            .padding(.top, CuePage.gap(before: .leading, joined: joined))
            .transition(.asymmetric(insertion: CueBubble.arrival(.leading, reduceMotion: reduceMotion), removal: .identity))
        } else if !landed {
            live
        }
        #else
        live
        #endif
    }

    @ViewBuilder private var live: some View {
        let presence = workspace.cue.presence
        if !roundInRows, let shown = presence.shown, let progress = presence.progress {
            RoundProcess(tools: nil, ending: .live(shown, doing: progress, step: nil))
                .padding(.leading, CueBubble.noteInset)
                .padding(.top, CuePage.gap(before: nil, joined: false))
                .transition(.asymmetric(insertion: .entry, removal: .identity))
        }
    }
}

