import CueStore
import SwiftUI
#if os(macOS)
import CuePi
#endif


/// Mac 上本机在线的会话（`slot`）在末尾逐字长出正在说的话（`SessionDraft`），说完落库时原位换下：这时对话里的回答都不淡入。
struct PiConversation: View {
    let session: PiSessionState
    let items: [PiChatEntry]
    let messages: [PiChatMessage]
    let window: ChatWindow
    /// 排在对话那一列里，它收起时正在读的不动（`ChatAnchor`）。
    var fetching = false
    #if os(macOS)
    var slot: PiBridge.Slot?
    #endif
    @Environment(\.chatHighlight) private var highlight
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .footnote) private var noticeText = ComposerMetrics.noticeTextHeight
    @State private var opened: PreviewOpening?

    var body: some View {
        let all = items
        let notes = services.settings.replyNotes(for: session.id)
        ChatStack(spacing: Self.spacing) {
            if fetching {
                Label("正在从 Mac 取对话…", icon: .fetching).font(Typography.meta).foregroundStyle(palette.ink3).frame(maxWidth: .infinity)
            }
            if all.allSatisfy(\.role.isOutgoing), let prompt = session.pendingPrompt ?? session.lastPrompt { RecapPreview(session: session, prompt: prompt) }
            ChatSegments(items: all, window: window, size: Self.segment) { items in
                ChatSegment(items: Array(items), session: session, highlight: highlight, notes: notes, swapsInPlace: swapsInPlace, opened: $opened)
                    .equatable()
            }
            ending
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        // 手机上长按出的是消息菜单，挑字、批注走菜单里的"选择文本""批注"：对话里的字不开行内选择，每行少建一套文字交互。
        // 挂在弹出预览之内：从这里打开的文件预览照常可选
        .environment(\.inlineTextSelection, false)
        #endif
        .previewPresenter($opened, reply: .session(session))
        .debugOpensPreview(in: items, session: session, $opened) { [workspace] in workspace.quote($0, in: $1, of: session) }
    }

    static var spacing: CGFloat { Spacing.block }
    static let firstWindow = 4, segment = 5
    static let paging = ChatPaging.fixed(first: firstWindow, step: segment)

    private var swapsInPlace: Bool {
        #if os(macOS)
        slot != nil
        #else
        false
        #endif
    }

    /// 进展的第一行一直占着位置（`ChatLiveSlot`，没有时留白）：一轮开始、结束时对话不跟着跳；进展往下长出的几步是内容。
    /// 它排在最后：回复框上方的说明（`composerNotice`）落在这段留白里，盖不到上面的内容。
    @ViewBuilder private var ending: some View {
        #if os(macOS)
        if let slot {
            SessionDraft(slot: slot, session: session, newestReply: messages.last { $0.role == .known(.pi) }, floating: floating)
        } else {
            ChatLiveSlot(spacing: Self.spacing, floating: floating) { liveStatus }
        }
        #else
        ChatLiveSlot(spacing: Self.spacing, floating: floating) { liveStatus }
        #endif
    }

    private var floating: CGFloat { ComposerMetrics.noticeClearance(textHeight: noticeText) }

    @ViewBuilder private var liveStatus: some View {
        if session.runtimeState.isWorking || !session.runtimeSubagents.isEmpty { LiveStatus(session: session).transition(.entry) }
    }
}


#if os(macOS)
/// 草稿落库了（`PiDraft.landed`）就不再显示：换下是同一帧里的一减一加。这一轮还在跑也不冒出进展（正文已经说完），只列子代理；状态先到时草稿照常留着、等文件。下一条助手消息开始时扩展清掉旧草稿。进展被草稿换下时直接拿掉，不叠着淡出。中途的话转成工具调用时桥清掉草稿，这里就让位给工具那一行。出字时只读草稿的视图重算，对话列表不重算。
struct SessionDraft: View {
    let slot: PiBridge.Slot
    let session: PiSessionState
    let newestReply: PiChatMessage?
    let floating: CGFloat

    var body: some View {
        let draft = slot.draft
        let landed = draft?.landed(newestReply: newestReply?.at, record: newestReply?.id) ?? false
        let speaking = draft != nil && !landed
        VStack(alignment: .leading, spacing: PiConversation.spacing) {
            if let draft, speaking {
                DraftReply(text: draft.text) {
                    if let ending = LiveStatus.ending(of: session, speaking: true) {
                        RoundProcess(tools: session.pendingTools, ending: ending)
                    }
                }
            }
            ChatLiveSlot(spacing: PiConversation.spacing, floating: floating) {
                if speaking || landed && session.runtimeState.known?.isTurnRunning == true {
                    PiSubagentList(agents: session.runtimeSubagents)
                } else if session.runtimeState.isWorking || !session.runtimeSubagents.isEmpty {
                    LiveStatus(session: session).transition(.asymmetric(insertion: .entry, removal: .identity))
                }
            }
        }
    }
}
#endif


/// 只按内容比较：同样的几条、描圈的那条与批注（只看本段里的）、同一个会话就不重算。
private struct ChatSegment: View, Equatable {
    let items: [PiChatEntry]
    let session: PiSessionState
    let highlight: UUID?
    let notes: [ReplyNote]
    let swapsInPlace: Bool
    @Binding var opened: PreviewOpening?
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

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
        ChatRows(ids: items.map(\.id), spacing: PiConversation.spacing) {
            ForEach(items) { item in row(item).benchSpot(item.id) }
        }
    }

    @ViewBuilder private func row(_ entry: PiChatEntry) -> some View {
        switch entry.role {
        case .user:
            UserBubble(stored: entry.text, look: .session, highlighted: entry.id == highlight, fromCue: entry.fromCue) {
                MessageActions(text: PiSkillCall.shown(entry.text), kind: .mine, session: session)
            }
                .padding(.top, Self.turnGap)
        case .outgoing(let request):
            outgoing(request).padding(.top, Self.turnGap)
        case .answer:
            // 你答了它的提问：你那一边的一颗气泡，字上面一行答的是哪个问题（问题答完就不在对话里了，引用不能点）
            AnswerBubble(answer: entry.text, quote: entry.question.map { BubbleQuote(text: $0) }, look: .session, highlighted: entry.id == highlight) {
                MessageActions(text: entry.text, kind: .mine, session: session)
            }
        case .pi:
            ReplyBlock(
                id: entry.id, text: entry.text, took: entry.took, tools: entry.tools, session: session, notes: notes.filter { $0.entry == entry.id }, fadesIn: !swapsInPlace)
        case .notice(let notice) where notice.changesContext:
            ContextBoundary(title: notice.label, highlighted: entry.id == highlight)
        case .notice(let notice):
            RoundEndNote(notice: notice)
        case .machine:
            MachineCards(text: entry.text)
        case .preview:
            PreviewBatch(previews: entry.previews, group: entry.id.uuidString, reply: { workspace.quote($0, in: entry.id, of: session) }) {
                opened = PreviewOpening(preview: $0, batch: entry.previews, group: entry.id.uuidString)
            }
        }
    }
}


extension ChatSegment {
    private func outgoing(_ request: DeliveryRequest) -> some View {
        let session = session, said = Said.request(request), box = services.settings.replyDraftBinding(for: session.id)
        return SpeechBubble(said: said, box: box, session: session, fromCue: request.isFromCue, look: .session) { trip in
            if trip.unconfirmedReason != nil {
                Button(MessageMenu.Item.copy.title, icon: MessageMenu.Item.copy.icon) { workspace.copy(request.content) }
            } else {
                MessageActions(
                    text: request.content, kind: .outgoing(failed: trip.failure != nil), session: session,
                    resend: { workspace.resend(said, restoringInto: box) }, remove: { workspace.remove(said) })
            }
        }
    }
}

/// 不是分隔（上下文没换），刻度滑条上也没有它。
private struct RoundEndNote: View {
    let notice: PiNotice

    var body: some View {
        NoteLine(icon: notice == .declined ? .declined : .endSession) { Text(verbatim: notice.label) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .transition(.entry)
    }
}

extension PiConversation {
    struct FollowKey: Equatable {
        var messages: Int
        var previews: Int
        var outgoing: [Speech.Trip]
        var state: Open<PiWorkState>?
    }

    static func followKey(
        session: PiSessionState?, messages: [PiChatMessage], previews: [PiPreview] = [], deliveries: [DeliveryRequest], at moment: Speech.Moment
    ) -> FollowKey {
        FollowKey(messages: messages.count, previews: previews.count, outgoing: PiChat.outgoing(deliveries, messages: messages).map { Speech.trip($0, at: moment) }, state: session?.state)
    }
}


/// 所在不放在这里（顶栏一行只说一件事），写在"⋯"菜单的最上面（`PiPlace.menuTitle`）。Mac 的会话栏头只写名字（`WideSessionTitle`）。
struct PiSessionSubtitle: View {
    let session: PiSessionState
    let delivery: DeliveryRequest?
    var undelivered: String?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    /// 会话在别的 Mac 上、本机正在和 iCloud 对（久过 `Pending.delay`）：写下的状态可能已经过时，先写"正在同步"（同 Cue 页头）。
    @State private var syncing = false

    var body: some View {
        let shown = workspace.shownInHeader(session, delivery: delivery)
        let speaks = syncing || shown.isRunning || shown.needsYou || [.ended, .cueAsking].contains(shown.status)
        let mark = session.agentMark
        // 什么都不写时也要有一个真的视图：等同步的那个任务挂在它上面
        ZStack(alignment: .leading) {
            if speaks || undelivered != nil || mark != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.tight) { facts(shown: shown, speaks: speaks, mark: mark, compact: false) }
                        .fixedSize()
                    HStack(spacing: Spacing.tight) { facts(shown: shown, speaks: speaks, mark: mark, compact: true) }
                }
                .font(Self.font)
                .relaySpot(session: session.sessionID)
                .accessibilityElement(children: .combine)
            }
        }
        .pending(services.isCatchingUp(on: session.hostID), shown: $syncing)
    }

    @ViewBuilder private func facts(shown: PiShown, speaks: Bool, mark: String?, compact: Bool) -> some View {
        if mark != nil {
            AgentMark(session: session, font: Self.font)
            if !compact, speaks || undelivered != nil { Dot().foregroundStyle(palette.ink3) }
        }
        if syncing { SyncingLabel() } else if speaks { PiShownLabel(shown: shown) }
        if let undelivered {
            if !compact, speaks { Dot().foregroundStyle(palette.failure) }
            Text(undelivered).foregroundStyle(palette.failure)
        }
        if !syncing, shown.isRunning, shown.clock != nil {
            if !compact { Dot().foregroundStyle(palette.ink3) }
            PiElapsed(shown: shown, font: Self.font, style: compact ? .span : .header)
        }
    }

    private static let font = Typography.caption
}

struct PiShownLabel: View {
    let shown: PiShown
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.tight) {
            #if os(iOS)
            PiStateDot(shown: shown, size: 6)
            #endif
            Text(shown.label).fontWeight(shown.needsYou ? .medium : nil).foregroundStyle(shown.labelTint(palette))
                .contentTransition(.opacity)
                .animation(Motion.fade, value: shown)
        }
    }
}


/// 只能在 Agent 那边答的（问题本身答不了，或这个会话做不到，`PiSessionState.answerableQuestion`）写明原文与去处。
struct PiQuestionDock: View {
    let session: PiSessionState
    var deliveries: [DeliveryRequest] = []

    var body: some View {
        DockedCard(session.runtimeState == .known(.waitingForUser) ? session : nil) { asked in
            if let question = asked.answerableQuestion {
                QuestionCard(session: asked, question: question, deliveries: deliveries).id(question.promptID)
            } else {
                // 去哪答写在回复框的位置上（各平台不同），这里只放问题
                Callout(.asking, text: asked.question?.displayText ?? asked.detail ?? "", docked: true)
            }
        }
    }
}
