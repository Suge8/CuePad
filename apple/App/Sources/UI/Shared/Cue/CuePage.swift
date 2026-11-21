import CueStore
import SwiftUI

/// Cue 页（窄屏的根，宽屏一直在右边），与会话页同一套消息版式，对话区也是同一个（`ChatColumn`）。
/// 页头点开都是 Cue 的面板（`CueNowPanel`，三端同一份）：记忆（`CueMemoryPage`）与定时（`CueSchedulePage`）从那里去。
/// 你发起的一轮在你的话之后先是这一轮的经过（`CueTrace`：碰到的任务与会话一处一行，做完一步才往下长、出现了就不再动），这一轮说的话与结果按先后在它之后。
/// Cue 自己醒来的几轮每轮一行旁注（`CueNoteLog`），末尾是它此刻在做什么（`CueEnding`：此刻在做的只写这里）。
/// 拍板卡（`CueWaitDock`）里是 Cue 的提问与会话在问的，对话里不另挂；通话在输入框里（`CueComposer`），Mac 通话中通话条顶替输入框（`CueVoicePanel`）。
/// 首次见面与启用只有一处（`CueWelcome`）：还没说过话时在正中，说过话后停用了在输入框正上方。
/// 说过话、启用着时，新来访时对话的尽头是舞台（`CueStage`）：打开停在它上面，往上滑是历史；你开口才收成末尾那一行。
/// 对话第一帧就排好（`observing` 当场读），停在最新处；有新消息时从第一条读起，还没读的气泡旁一颗小点（`CueViewing`）。
/// Cue 运行在别的设备上、本机正在和 iCloud 对时（`AppServices.isCatchingUp(on:)`）页头写"正在同步"，这期间到的话先不滑上来，
/// 对完一次滑上来（`ChatColumn` 的 `holding`）：对完才算开始看，有新消息就到第一条新消息、从它读起，没有才到最新处（`CueViewing`）。
/// Cue 在做的事在任务与 Agent 页里看，这里不另列。
/// 页面只读写库：写一条你的消息就是对 Cue 说话，Cue 运行在哪台 Mac 都一样。
struct CuePage: View {
    /// 页自己铺桌面色；Mac 右边那一栏垫着浮板的玻璃（`CueColumn`），不铺。
    var grounded = true
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.headerHost) private var headerHost
    #endif
    @State private var thread: CueThread?
    @State private var follow = ChatFollow()
    @State private var opened: PreviewOpening?
    /// 拍板卡正在来去（`CueWaitDock.moving`）：对话先不往上滑。
    @State private var docking = false
    /// 上一次更新时在等的那张卡：答完的那一次更新里卡已不在数据里，对话同时长出这一问与回答，`docking` 却要等卡收到才起（晚一次更新），
    /// 这一下按它补上（`sinking`），不让对话当帧顶上去一截再随卡沉回落下来。
    @State private var dockedCard: String?
    /// 末尾在屏上的新消息（`CueViewing`）。
    @State private var seen: [UUID: Date] = [:]
    /// 舞台开着（`CueStage`）：页出现时与新来访时（`CueViewing`）按上次离开的时刻定，输入框聚焦、发出时收。
    /// 还没定（nil）时对话区空这一帧：先排一帧对话再换成舞台是一闪。
    @State private var stage: Bool?
    /// 舞台上云下那几件（`CueBrief`），舞台开着时才读。
    @State private var brief: CueBrief?
    /// 舞台开起来的那一刻：天空按它取时段（`CueStage.Period`），开着的期间不换。
    @State private var stagedAt = Date.now
    /// 舞台此刻在可见区里：名牌让开、Mac 不垫托底（后面是天空）。往上看历史时它不在。
    @State private var stageInView = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let readingWidth = Spacing.reading
    static let inset = Spacing.page

    private var cue: CueWatch { workspace.cue }
    private func card(_ thread: CueThread) -> String? { CueWaitDock.current(in: thread.waiting, asking: workspace.cueAsking)?.id }
    private func sinking(_ thread: CueThread) -> Bool { dockedCard != nil && card(thread) == nil }
    private var catchingUp: Bool { services.syncing.isCatchingUp(on: cue.hostID) }
    var body: some View {
        page
            .observing(services.store, into: $thread, onError: workspace.fail) { try CueThread.read(from: $0) }
            .previewPresenter($opened, reply: .cue)
            .panel(isPresented: Bindable(cue).showsMemory) { CueMemoryPage() }
            .panel(isPresented: Bindable(cue).showsSchedules) { CueSchedulePage() }
            .modifier(CueViewing(thread: thread, catchingUp: catchingUp, seen: $seen, follow: $follow, staged: staged) {
                guard DebugHooks.preset.cueStage == nil else { return }
                stage = true
                stagedAt = .now
                follow.jumpToNewest()
            })
            .onAppear { if stage == nil { stage = DebugHooks.preset.cueStage ?? CueStage.opens(left: services.settings.cueLeft, at: .now) } }
            .onChange(of: thread.flatMap(card), initial: true) { dockedCard = $1 }
            .onChange(of: thread != nil, initial: true) { _, loaded in
                guard loaded else { return }
                DebugHooks.mark("cue")
            }
    }

    #if os(macOS)
    private var page: some View {
        FloatingReply {
            chat.frame(maxWidth: .infinity, maxHeight: .infinity)
        } reply: {
            bottom()
                .replyTray(!(staged && stageInView))
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: Self.readingWidth)
        }
        .background { if grounded { palette.desk } }
    }
    #else
    /// 名牌保留整页坐标；对话与拍板卡两侧都给常驻会话条让位、按整屏居中，舞台的天空铺到会话条底下（伸出读宽，`CueStage`）。
    private var page: some View {
        FloatingReply {
            chat
        } reply: {
            bottom()
                .padding(.horizontal, Spacing.group)
                .frame(maxWidth: Self.readingWidth)
        }
        .scrollDismissesKeyboard(.interactively)
        // 同会话页：对话滑到页头的玻璃下面，只有状态栏那一条由窗口的模糊盖着（`StatusBarBlur`），不再垫系统的淡出
        .scrollEdgeEffectHidden(true, for: .top)
        // iPad 右边那一栏：名牌比栏窄，对话到名牌下沿淡出，不从名牌两侧露出来（`Bars`）；手机的名牌铺满整行，照沉浸式
        .fadesUnderHead(headerHost == .panel && !(staged && stageInView))
        .floatingHeader(.verbatim(cue.name), height: CueHeader.height, hasPanel: true, center: { CueHeader(staged: staged && stageInView) }) { EmptyView() }
    }
    #endif

    /// 对话自己离两边 `inset`：两边都让到字离会话条一个 `item`，左右对称，对话与页头、输入框同一条中线。
    /// 对话里让在滚动区自己的边距里（`ChatColumn` 的 `inset`），不在外面缩滚动区：缩了的话舞台的天空画不出滚动区，两边露出两条底。
    private var railInset: CGFloat { workspace.layout == .narrow ? SessionRail.phoneWidth + Spacing.item - Self.inset : 0 }

    private var staged: Bool { stage == true && cue.canHear && thread?.rows.isEmpty == false }

    /// 读不出来时也排一个真的视图：读库的订阅挂在页上，等视图出现才启动。
    @ViewBuilder private var chat: some View {
        Group {
            if let thread, !thread.rows.isEmpty {
                if stage != nil {
                    conversation(thread)
                } else {
                    Color.clear
                }
            } else if thread != nil {
                CueWelcomeChat().padding(.horizontal, railInset)
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
            followKey: FollowKey(thread, live: cue.presence.shown != nil), readingWidth: Self.readingWidth, inset: Self.inset + railInset, follow: $follow,
            marks: thread.marks, ids: rows.map(\.id), paging: Self.paging(thread),
            holding: catchingUp || docking || sinking(thread),
            arrival: rows.last.flatMap { CueRow.arrives($0, swapsInPlace: services.cueOnDutyHere) ? $0.id : nil }
        ) { window in
            let lastYou = thread.messages.last { $0.author == .known(.you) }?.id
            ChatStack(spacing: 0) {
                ChatSegments(items: rows, window: window, size: Self.segment, spare: Self.spare) { items in
                    CueSegment(rows: items.map { item in
                        CueRow(
                            row: item, shots: thread.shots[item.id] ?? [],
                            joined: thread.joined.contains(item.id),
                            stamp: thread.stamps[item.id], delivered: item.id == lastYou,
                            unread: thread.unread.contains(item.id), settled: item.id != rows.last?.id, opened: $opened, seen: $seen)
                    })
                    .equatable()
                }
                if staged {
                    stageView(thread)
                } else {
                    CueEnding(
                        newestSaid: thread.messages.last { $0.author == .known(.cue) }?.createdAt, joined: rows.last?.speaker == .leading)
                }
            }
            #if os(iOS)
            // 手机上对话里的字不开行内选择：长按出的是消息菜单，挑字走菜单里的"选择文本"（同会话页）
            .environment(\.inlineTextSelection, false)
            #endif
        }
    }

    private func stageView(_ thread: CueThread) -> some View {
        let replies = cue.now.items.filter { $0.kind == .reply }, said = CueBrief.said(thread)
        let room = CueBrief.limit - (said == nil ? 0 : 1)
        return CueStage(
            beat: cue.beat, status: cue.now.quietLine, brief: (said.map { [$0] } ?? []) + (brief?.lines ?? []),
            period: CueStage.Period(at: stagedAt, dark: palette.dark), open: openBrief)
            .onScrollVisibilityChange(threshold: 0.4) { stageInView = $0 }
            .observing(services.store, id: [String(room)] + replies.map(\.id), into: $brief, onError: workspace.fail) { [replies] in
                try CueBrief.read(replies: replies, room: room, from: $0)
            }
            .transition(.opacity)
    }

    private func openBrief(_ line: CueBrief.Line) {
        switch line.go {
        case .session(let session): workspace.openSession(SessionState.recordID(sessionID: session), sessionID: session)
        case .message(let id): follow.seek(id)
        }
    }

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

    private func bottom() -> some View {
        VStack(spacing: 0) {
            if let thread {
                CueWaitDock(waiting: thread.waiting, asking: workspace.cueAsking, shots: thread.shots, open: { opened = $0 }, moving: $docking)
                    .padding(.horizontal, railInset)
                if !thread.rows.isEmpty, !cue.canHear { CueWelcome(intro: false).fixedSize(horizontal: false, vertical: true).padding(.bottom, Spacing.item).transition(.opacity) }
            }
            #if os(macOS)
            CueVoicePanel()
            #endif
            // 宽屏没启用时不放输入框：这一栏只剩启用那一张（`CueWelcome`）
            // Mac 通话中通话条原地顶替输入框（同手机，`CueVoiceView`），挂断了输入框回来、草稿还在
            if !calling, cue.canHear || workspace.layout == .narrow {
                CueComposer(style: .page, takesFocusRequests: true, focusing: closeStage) {
                    follow.sent()
                    closeStage()
                }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.fade, value: cue.canHear)
        .animation(Motion.fade, value: calling)
    }

    private func closeStage() {
        guard stage == true else { return }
        stageInView = false
        withAnimation(Motion.fading(Motion.travel, reduceMotion: reduceMotion)) { stage = false }
    }

    private var calling: Bool {
        #if os(macOS)
        workspace.voiceViewState.presentation().active
        #else
        false
        #endif
    }
}

/// 在 FloatingReply 的内容里读回复框留白；空态也要能滚到被回复框盖住的建议。
private struct CueWelcomeChat: View {
    @Environment(\.chatBottomInset) private var replyInset

    var body: some View {
        GeometryReader { room in
            ScrollView {
                CueWelcome(intro: true)
                    .padding(.horizontal, CuePage.inset)
                    .frame(maxWidth: CuePage.readingWidth)
                    .frame(maxWidth: .infinity, minHeight: max(0, room.size.height - replyInset))
            }
            .safeAreaPadding(.bottom, replyInset)
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}
