import CueStore
import SwiftUI
#if os(macOS)
import CuePi
#endif


/// 会话页的对话（iOS 会话页、Mac 会话页共用）：你的话右侧墨色气泡，Pi 的回答左侧全宽 Markdown（一直展开），
/// 每轮回答上方一块这一轮的经过（`RoundProcess`）；你发出、Agent 还没读到也不在排队的话接在末尾，气泡下写送达情况，失败的可重发
/// （排队的在回复框上方，`PiQueueStack`）；Pi 在处理时末尾是这一轮到目前为止的经过与正在跑的那一步（`LiveStatus`；计时在顶上一行），
/// 有子代理时下面逐个列出它们此刻的状态；出错时末尾写原因。滚动与输入框由平台放。
/// Mac 上本机在线的会话（`slot`）在末尾逐字长出正在说的话（`SessionDraft`），说完落库时原位换下：这时对话里的回答都不淡入。
/// 减弱动态效果下也只有淡入淡出。
struct PiConversation: View {
    let session: PiSessionState
    /// 对话里的每一条（`ChatDerived` 按对话数据推好的）。
    let items: [PiChatEntry]
    /// 发出还没进对话的话要对着已有的消息认。
    let messages: [PiChatMessage]
    var deliveries: [DeliveryRequest] = []
    /// 至少排开最近这么多条（不用懒加载栈，见 `ChatScroll`）；更早的由 `showEarlier` 再排开一段。
    let window: Int
    var showEarlier: () -> Void = {}
    #if os(macOS)
    /// 这个会话在本机桥上的那一格（在线时）：正在说的话从这里读。
    var slot: PiBridge.Slot?
    #endif
    @Environment(\.chatHighlight) private var highlight
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @State private var opened: PreviewOpening?
    /// 整列的宽：离屏远的段换成的空白按它估高（`ChatSegments`）。
    @State private var width: CGFloat = 0

    var body: some View {
        let all = items
        let notes = services.settings.replyNotes(for: session.id)
        let first = Self.firstSegment(count: all.count, window: window)
        VStack(alignment: .leading, spacing: Self.spacing) {
            if first > 0 {
                EarlierRow(count: Self.segment, action: showEarlier)
            }
            if all.isEmpty, let prompt = session.pendingPrompt ?? session.lastPrompt { RecapPreview(session: session, prompt: prompt) }
            ChatSegments(items: all, size: Self.segment, first: first, width: width, pinned: { $0.contains { $0.id == highlight } }) { items in
                ChatSegment(items: Array(items), session: session, highlight: highlight, notes: notes, swapsInPlace: swapsInPlace, opened: $opened)
                    .equatable()
            }
            ForEach(PiChat.outgoing(deliveries, messages: messages, at: services.speech)) { request in outgoing(request) }
            ending
        }
        // 刻度滑条按 id 跳到你的某句话（`ChatFollow.jump`）：滚动区只认滚动目标布局里的行
        .scrollTargetLayout()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
        #if os(iOS)
        // 手机上长按出的是消息菜单，挑字走菜单里的"选择文本"：对话里的字不开行内选择，每行少建一套文字交互。
        // 挂在弹出预览之内：从这里打开的文件预览照常可选
        .environment(\.inlineTextSelection, false)
        #endif
        .previewPresenter($opened)
        .debugOpensPreview(in: items, session: session, $opened)
    }

    /// 你发出、还没进对话的一句：说的话的气泡，还在路上时写会话这边的说法（排队中、送达中；已结束的会话先唤醒）。
    private func outgoing(_ request: DeliveryRequest) -> some View {
        let session = session, said = Said.request(request)
        return SpeechBubble(
            said: said, box: services.settings.replyDraftBinding(for: session.id),
            transit: .of(request, session: session), fromCue: request.isFromCue
        ) { trip in
            let failed = if case .failed = trip { true } else { false }
            MessageActions(
                text: request.content, kind: .outgoing(failed: failed), session: session,
                resend: { workspace.resend(said, restoringInto: services.settings.replyDraftBinding(for: session.id)) },
                remove: { workspace.remove(said) })
        }
    }

    static var spacing: CGFloat { 16 }
    /// 最初至少排开几条；一段几条（每次再排开一段）。段按从最早那条起的位置切，排开更早的只是在上面多显示一段，已有的段不变。
    static let firstWindow = 4, segment = 5
    static let paging = ChatPaging.fixed(first: firstWindow, step: segment)

    /// 排开最近 `window` 条要从第几段起。
    static func firstSegment(count: Int, window: Int) -> Int { max(0, count - window) / segment }

    /// 回答原位换下正在说的话（Mac 上本机在线的会话），不淡入。
    private var swapsInPlace: Bool {
        #if os(macOS)
        slot != nil
        #else
        false
        #endif
    }

    /// 对话末尾：正在说的话或处理中的进展（带子代理）、出错的原因（Agent 已把这次错误写成最后一条回答时不再重复）。
    @ViewBuilder private var ending: some View {
        #if os(macOS)
        if let slot {
            SessionDraft(slot: slot, session: session, newestReply: messages.last { $0.role == .known(.pi) }?.at)
        } else {
            liveStatus
        }
        #else
        liveStatus
        #endif
        if session.state == .known(.error), !PiErrorSummary.echoes(messages.last { $0.role == .known(.pi) }?.text, line: session.detail) {
            Callout(.failed, text: session.detail ?? "Mac 没有说明原因")
        }
    }

    @ViewBuilder private var liveStatus: some View {
        if session.state.isWorking || !session.subagents.isEmpty { LiveStatus(session: session).transition(.entry) }
    }
}


#if os(macOS)
/// 会话页对话的末尾（Mac，本机在线的会话）：正在说的话（`PiBridge.Slot.draft`）出字时逐字长出来（`DraftReply`，上方是这一轮的经过，标题行末写"输出中"），
/// 没有时是进展那一行（`LiveStatus`）——中途的话转成工具调用时桥清掉草稿，这里就让位给工具那一行。出字时只读草稿的视图重算，对话列表不重算。
/// 草稿落库了（`PiDraft.landed`）就不再显示：换下是同一帧里的一减一加。这一轮还在跑也不冒出进展那一行（正文已经说完）；
/// 状态先到时草稿照常留着、等文件。下一条助手消息开始时扩展清掉旧草稿。进展行被草稿换下时直接拿掉，不叠着淡出。
struct SessionDraft: View {
    let slot: PiBridge.Slot
    let session: PiSessionState
    /// 对话里最近一条 Agent 回答的时刻
    let newestReply: Date?

    var body: some View {
        let draft = slot.draft
        let landed = draft?.landed(newestReply: newestReply) ?? false
        if let draft, !landed {
            VStack(alignment: .leading, spacing: 8) {
                DraftReply(text: draft.text) {
                    if let ending = LiveStatus.ending(of: session, speaking: true) {
                        RoundProcess(tools: session.pendingTools, ending: ending)
                    }
                }
                PiSubagentList(agents: session.subagents)
            }
        } else if landed, session.state.known?.isTurnRunning == true {
            PiSubagentList(agents: session.subagents)
        } else if session.state.isWorking || !session.subagents.isEmpty {
            LiveStatus(session: session).transition(.asymmetric(insertion: .entry, removal: .identity))
        }
    }
}
#endif


/// 对话里的一段（`PiConversation.segment` 条）。只按内容比较：同样的几条、描圈的那条与批注（只看本段里的）、同一个会话就不重算。
private struct ChatSegment: View, Equatable {
    let items: [PiChatEntry]
    let session: PiSessionState
    let highlight: UUID?
    let notes: [ReplyNote]
    let swapsInPlace: Bool
    @Binding var opened: PreviewOpening?

    init(items: [PiChatEntry], session: PiSessionState, highlight: UUID?, notes: [ReplyNote], swapsInPlace: Bool, opened: Binding<PreviewOpening?>) {
        self.items = items
        self.session = session
        self.swapsInPlace = swapsInPlace
        self.highlight = highlight.flatMap { id in items.contains { $0.id == id } ? id : nil }
        self.notes = notes.filter { note in items.contains { $0.id == note.entry } }
        _opened = opened
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.highlight == rhs.highlight && lhs.notes == rhs.notes && lhs.swapsInPlace == rhs.swapsInPlace
            && lhs.session.id == rhs.session.id && lhs.session.projectID == rhs.session.projectID
    }

    private static var turnGap: CGFloat { 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: PiConversation.spacing) {
            ForEach(items) { item in row(item) }
        }
    }

    @ViewBuilder private func row(_ entry: PiChatEntry) -> some View {
        switch entry.role {
        case .user:
            UserBubble(stored: entry.text, highlighted: entry.id == highlight, fromCue: entry.fromCue) {
                MessageActions(text: entry.text, kind: .mine, session: session)
            }
                // 你的话开始新的一轮：轮与轮之间比轮内（你的话与它的回答）松一截
                .padding(.top, Self.turnGap)
        case .pi:
            ReplyBlock(
                text: entry.text, took: entry.took, tools: entry.tools, session: session, notes: notes.filter { $0.entry == entry.id }, fadesIn: !swapsInPlace)
        case .notice(let notice) where notice.changesContext:
            // 压缩：上下文从这里起换了，与 Cue 换新同一条分隔
            ContextBoundary(title: entry.text, highlighted: entry.id == highlight)
        case .notice(let notice):
            RoundEndNote(notice: notice)
        case .machine:
            MachineCards(text: entry.text)
        case .preview:
            PreviewBatch(previews: entry.previews, group: entry.id.uuidString) {
                opened = PreviewOpening(preview: $0, batch: entry.previews, group: entry.id.uuidString, reply: .session(session))
            }
        }
    }
}


/// 这一轮怎么结束的（被停下、被你拒绝）：回答下面一行旁注，不是分隔（上下文没换），刻度滑条上也没有它。
private struct RoundEndNote: View {
    let notice: PiNotice

    var body: some View {
        NoteLine(icon: notice == .declined ? .declined : .endSession) { Text(notice.rawValue) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .transition(.entry)
    }
}

/// 排开的最上面一行：还有更早的对话（居中的标记）。往上翻快到这里时会自动再排开一段（`ChatFollow.nearOldest`），点它（读屏）也能排开。
struct EarlierRow: View {
    /// 点一下再排开几条。
    let count: Int
    let action: () -> Void

    var body: some View {
        ChatMarker(action: action) { Label("更早的 \(count) 条", icon: .earlier).labelStyle(.titleAndIcon) }
    }
}


extension PiConversation {
    /// 对话里"有新内容"的标志（滚动跟随用，见 `ChatScroll`）：多了消息、发出的话或它的送达情况变了、开始或结束处理、出错。
    struct FollowKey: Equatable {
        var messages: Int
        var previews: Int
        var outgoing: [Speech.Trip]
        var state: Open<PiWorkState>?
    }

    static func followKey(
        session: PiSessionState?, messages: [PiChatMessage], previews: [PiPreview] = [], deliveries: [DeliveryRequest], at moment: Speech.Moment
    ) -> FollowKey {
        FollowKey(messages: messages.count, previews: previews.count, outgoing: PiChat.outgoing(deliveries, messages: messages, at: moment).map { Speech.trip($0, at: moment) }, state: session?.state)
    }
}


/// 会话顶栏（Mac 工具栏标题、手机顶栏）里名字旁的状态，只在在跑或要你注意时出现：在跑（工作中、话在路上）是状态标、状态词与到秒的计时；
/// 等你确认、出错、没能送达、需要 /reload、已结束只有状态标与状态词（带色）。Mac 不画状态标，只有着色的字：标题玻璃里唯一的圆是任务的完成圈；有没送到的话时接一句胭脂的"N 句没送到"（`PiChat.undeliveredNote`）。
/// 最前面写是哪家 Agent（`AgentMark`），歇着时也写；歇着（该你了、新会话、有新回复）时只有它。所在与"后台"不放在这里（顶栏一行只说一件事），写在"⋯"菜单的最上面（`PiPlace.menuTitle`）。
struct PiSessionSubtitle: View {
    let session: PiSessionState
    var undelivered: String?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    /// 会话在别的 Mac 上、本机正在和 iCloud 对（久过 `Pending.delay`）：写下的状态可能已经过时，先写"正在同步"（同 Cue 页头）。
    @State private var syncing = false

    var body: some View {
        let shown = workspace.shownInHeader(session)
        let speaks = syncing || shown.isLive || shown.needsYou || [.restart, .ended, .cueAsking].contains(shown.status)
        let mark = session.agentMark
        // 什么都不写时也要有一个真的视图：等同步的那个任务挂在它上面
        ZStack(alignment: .leading) {
            if speaks || undelivered != nil || mark != nil {
                HStack(spacing: 4) {
                    if mark != nil {
                        AgentMark(session: session, font: Self.font)
                        if speaks || undelivered != nil { Dot().foregroundStyle(palette.ink3) }
                    }
                    if syncing { SyncingLabel() } else if speaks { PiShownLabel(shown: shown) }
                    if let undelivered {
                        if speaks { Dot().foregroundStyle(palette.failure) }
                        Text(undelivered).foregroundStyle(palette.failure)
                    }
                    if !syncing, shown.isLive, shown.clock != nil {
                        Dot().foregroundStyle(palette.ink3)
                        // 整个 App 只有这一个计时到秒：正看着的这个会话
                        PiElapsed(shown: shown, font: Self.font, style: .header)
                    }
                }
                .font(Self.font)
                .fixedSize()
                .relaySpot(session: session.sessionID)
                .accessibilityElement(children: .combine)
            }
        }
        .pending(services.isCatchingUp(on: session.hostID), shown: $syncing)
    }

    private static let font = Typography.caption
}

/// 顶栏里的状态（会话页与 Cue 页同一个样子）：着色的状态词，手机上前面加状态标（Mac 的标题玻璃里不画圆）。
struct PiShownLabel: View {
    let shown: PiShown
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            #if os(iOS)
            PiStateDot(shown: shown, size: 6)
            #endif
            Text(shown.label).fontWeight(shown.needsYou ? .medium : nil).foregroundStyle(shown.labelTint(palette))
                .contentTransition(.opacity)
                .animation(Motion.quick, value: shown)
        }
    }
}


/// 等你确认时固定在输入框上方的问题：能从这里答的是问题卡（选项一点即答，答完随问题清空而消失），
/// 只能在 Agent 那边答的（问题本身答不了，或这个会话做不到，`PiSessionState.answerableQuestion`）写明原文与去处。
struct PiQuestionDock: View {
    let session: PiSessionState
    var deliveries: [DeliveryRequest] = []

    var body: some View {
        if session.state == .known(.waitingForUser) {
            if let question = session.answerableQuestion {
                QuestionCard(session: session, question: question, deliveries: deliveries).id(question.promptID)
            } else {
                // 去哪答写在回复框的位置上（各平台不同），这里只放问题
                Callout(.asking, text: session.question?.displayText ?? session.detail ?? "", docked: true)
            }
        }
    }
}
