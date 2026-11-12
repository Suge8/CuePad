import CueStore
import SwiftUI

/// Cue 页（窄屏的根，宽屏一直在右边），与会话页同一套消息版式，对话区也是同一个（`ChatColumn`）。
/// 页头点开都是 Cue 的面板（`CueNowPanel`，三端同一份）：记忆（`CueMemoryPage`）与定时（`CueSchedulePage`）从那里去，Cue 在这台 Mac 值班时 Mac 的面板末尾还有"运行情况"，在右侧开一栏（`CueRunPanel`）。
/// 你发起的一轮在你的话之后先是这一轮的经过（`CueTrace`：碰到的任务与会话一处一行，做完一步才往下长、出现了就不再动），这一轮说的话与结果按先后在它之后。
/// Cue 自己醒来的几轮每轮一行旁注（`CueNoteLog`），末尾是它此刻在做什么（`CueEnding`：此刻在做的只写这里）。
/// 拍板卡（`CueWaitDock`）里是 Cue 的提问与会话在问的，对话里不另挂；通话在输入框里（`CueComposer`），Mac 的通话条在栏顶（`CueVoicePanel`）。
/// 首次见面与启用只有一处（`CueWelcome`）：还没说过话时在正中，说过话后停用了在输入框正上方。
/// 对话第一帧就排好（`observing` 当场读），停在最新处；有新消息时从第一条读起，还没读的气泡旁一颗小点（`CueViewing`）。
/// Cue 运行在别的设备上、本机正在和 iCloud 对时（`AppServices.isCatchingUp(on:)`）页头写"正在同步"，这期间到的话先不滑上来，
/// 对完一次滑上来（`ChatColumn` 的 `holding`）：对完才算开始看，有新消息就到第一条新消息、从它读起，没有才到最新处（`CueViewing`）。
/// Cue 在做的事在任务与 Agent 页里看，这里不另列。
/// 页面只读写库：写一条你的消息就是对 Cue 说话，Cue 运行在哪台 Mac 都一样。
struct CuePage: View {
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
    /// 末尾在屏上的新消息（`CueViewing`）。
    @State private var seen: [UUID: Date] = [:]

    static let readingWidth = Spacing.reading
    static let inset = Spacing.page

    private var cue: CueWatch { workspace.cue }
    private var catchingUp: Bool { services.isCatchingUp(on: cue.hostID) }
    var body: some View {
        page
            .observing(services.store, into: $thread, onError: workspace.fail) { try CueThread.read(from: $0) }
            .previewPresenter($opened, reply: .cue)
            .panel(isPresented: Bindable(cue).showsMemory) { CueMemoryPage() }
            .panel(isPresented: Bindable(cue).showsSchedules) { CueSchedulePage() }
            .modifier(CueViewing(thread: thread, catchingUp: catchingUp, seen: $seen, follow: $follow))
            .onChange(of: thread != nil, initial: true) { _, loaded in
                guard loaded else { return }
                DebugHooks.mark("cue")
            }
    }

    #if os(macOS)
    private var page: some View {
        HStack(spacing: 0) {
            FloatingReply {
                VStack(spacing: 0) {
                    CueVoicePanel()
                    chat.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } reply: {
                bottom()
                    .replyTray()
                    .padding(.horizontal, Self.inset)
                    .frame(maxWidth: Self.readingWidth)
            }
            // 原地淡入淡出、对话这一下就让到终点的宽：开合不逐帧排版
            if cue.showsRun, let keeper = services.cue.keeper {
                CueRunPanel(keeper: keeper)
                    .padding([.trailing, .bottom], Spacing.group)
                    .transition(.opacity.animation(Motion.fade))
            }
        }
        .background(palette.desk)
    }
    #else
    /// 名牌保留整页坐标；仅对话与拍板卡给常驻会话条让位。
    private var page: some View {
        FloatingReply {
            chat.padding(.leading, railInset)
        } reply: {
            bottom()
                .padding(.horizontal, Spacing.group)
                .frame(maxWidth: Self.readingWidth)
        }
        .scrollDismissesKeyboard(.interactively)
        // iPad 右边那一栏：名牌比栏窄，对话到名牌下沿淡出，不从名牌两侧露出来（`Bars`）；手机的名牌铺满整行，照沉浸式
        .fadesUnderHead(headerHost == .panel)
        .floatingHeader(.verbatim(cue.name), height: CueHeader.height, hasPanel: true, center: { CueHeader() }) { EmptyView() }
    }
    #endif

    private var railInset: CGFloat { workspace.layout == .narrow ? SessionRail.chatInset : 0 }

    /// 读不出来时也排一个真的视图：读库的订阅挂在页上，等视图出现才启动。
    @ViewBuilder private var chat: some View {
        Group {
            if let thread, !thread.rows.isEmpty {
                conversation(thread)
            } else if thread != nil {
                CueWelcomeChat()
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
            arrival: rows.last.flatMap { CueRow.arrives($0, swapsInPlace: services.cueOnDutyHere) ? $0.id : nil },
            docked: CueWaitDock.current(in: thread.waiting, asking: workspace.cueAsking)?.id
        ) { window in
            let lastYou = thread.messages.last { $0.author == .known(.you) }?.id
            ChatStack(spacing: 0) {
                ChatSegments(items: rows, window: window, size: Self.segment, spare: Self.spare) { items in
                    CueSegment(rows: items.map { item in
                        CueRow(
                            row: item, shots: thread.shots[item.id] ?? [],
                            joined: thread.joined.contains(item.id),
                            stamp: thread.stamps[item.id], delivered: item.id == lastYou,
                            unread: thread.unread.contains(item.id), opened: $opened, seen: $seen)
                    })
                    .equatable()
                }
                CueEnding(
                    newestSaid: thread.messages.last { $0.author == .known(.cue) }?.createdAt, joined: rows.last?.speaker == .leading)
            }
            #if os(iOS)
            // 手机上对话里的字不开行内选择：长按出的是消息菜单，挑字走菜单里的"选择文本"（同会话页）
            .environment(\.inlineTextSelection, false)
            #endif
            .animation(Motion.fade, value: cue.presence.progress)
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
                    .padding(.leading, railInset)
                if !thread.rows.isEmpty, !cue.canHear { CueWelcome(intro: false).fixedSize(horizontal: false, vertical: true).padding(.bottom, Spacing.item).transition(.opacity) }
            }
            // 宽屏没启用时不放输入框：主区底部已有记下灵感的那一条（`CaptureSlot`），一屏只留一个；这一栏只剩启用那一张（`CueWelcome`）
            if cue.canHear || workspace.layout == .narrow {
                CueComposer(style: .page, takesFocusRequests: true) { follow.sent() }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.fade, value: cue.canHear)
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
