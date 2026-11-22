import CueStore
import SwiftUI
#if os(macOS)
import CueBridge
#endif


struct Conversation: View {
    let session: SessionState
    let items: [ChatEntry]
    let messages: [ChatMessage]
    let window: ChatWindow
    var fetching = false
    #if os(macOS)
    var slot: Bridge.Slot?
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

    private var liveStatus: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if session.runtimeState.isWorking || !session.runtimeSubagents.isEmpty { LiveStatus(session: session).transition(.entry) }
            LiveFigure(live: FigureLive(session: session), handoff: FigureHandoff(reply: messages.last { $0.role == .known(.pi) }?.at))
        }
    }
}


#if os(macOS)
struct SessionDraft: View {
    let slot: Bridge.Slot
    let session: SessionState
    let newestReply: ChatMessage?
    let floating: CGFloat

    var body: some View {
        let draft = slot.draft
        let landed = draft?.landed(newestReply: newestReply?.at, record: newestReply?.id) ?? false
        let speaking = draft != nil && !landed
        VStack(alignment: .leading, spacing: Conversation.spacing) {
            if let draft, speaking {
                DraftReply(text: draft.text) {
                    if let ending = LiveStatus.ending(of: session, speaking: true) {
                        RoundProcess(tools: session.pendingTools, ending: ending, session: session)
                    }
                }
            }
            ChatLiveSlot(spacing: Conversation.spacing, floating: floating) {
                let said = speaking || landed && session.runtimeState.known?.isTurnRunning == true
                VStack(alignment: .leading, spacing: Spacing.item) {
                    if said {
                        SubagentList(agents: session.runtimeSubagents)
                    } else if session.runtimeState.isWorking || !session.runtimeSubagents.isEmpty {
                        LiveStatus(session: session).transition(.asymmetric(insertion: .entry, removal: .identity))
                    }
                    LiveFigure(live: said ? nil : FigureLive(session: session), handoff: FigureHandoff(reply: newestReply?.at, speaking: speaking))
                }
            }
        }
    }
}
#endif


private struct ChatSegment: View, Equatable {
    let items: [ChatEntry]
    let session: SessionState
    let highlight: UUID?
    let notes: [ReplyNote]
    let swapsInPlace: Bool
    @Binding var opened: PreviewOpening?
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

    init(items: [ChatEntry], session: SessionState, highlight: UUID?, notes: [ReplyNote], swapsInPlace: Bool, opened: Binding<PreviewOpening?>) {
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

    private static var turnGap: CGFloat { Spacing.block }

    var body: some View {
        ChatRows(ids: items.map(\.id), spacing: Conversation.spacing) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item, last: !(items.indices.contains(index + 1) && items[index + 1].role.isOutgoing)).benchSpot(item.id)
            }
        }
    }

    @ViewBuilder private func row(_ entry: ChatEntry, last: Bool) -> some View {
        switch entry.role {
        case .user:
            UserBubble(stored: entry.text, look: .session, highlighted: entry.id == highlight, fromCue: entry.fromCue) {
                MessageActions(text: SkillCall.shown(entry.text), kind: .mine, session: session)
            }
                .padding(.top, Self.turnGap)
        case .outgoing(let request):
            outgoing(request, marksTransit: last).padding(.top, Self.turnGap)
        case .answer:
            AnswerBubble(answer: entry.text, quote: entry.question.map { BubbleQuote(text: $0) }, look: .session, highlighted: entry.id == highlight) {
                MessageActions(text: entry.text, kind: .mine, session: session)
            }
        case .pi:
            ReplyBlock(
                id: entry.id, text: entry.text, took: entry.took, tools: entry.tools, session: session, notes: notes.filter { $0.entry == entry.id },
                fadesIn: !swapsInPlace)
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
    private func outgoing(_ request: DeliveryRequest, marksTransit: Bool) -> some View {
        let session = session, said = Said.request(request), box = services.settings.replyDraftBinding(for: session.id)
        return SpeechBubble(said: said, box: box, session: session, fromCue: request.isFromCue, marksTransit: marksTransit, look: .session) { trip in
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

private struct RoundEndNote: View {
    let notice: ChatNotice

    var body: some View {
        NoteLine(icon: notice == .declined ? .declined : .endSession) { Text(verbatim: notice.label) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .transition(.entry)
    }
}

extension Conversation {
    struct FollowKey: Equatable {
        var messages: Int
        var previews: Int
        var outgoing: [Speech.Trip]
        var state: Open<WorkState>?
    }

    static func followKey(
        session: SessionState?, messages: [ChatMessage], previews: [PreviewItem] = [], deliveries: [DeliveryRequest], at moment: Speech.Moment
    ) -> FollowKey {
        FollowKey(messages: messages.count, previews: previews.count, outgoing: Chat.outgoing(deliveries, messages: messages).map { Speech.trip($0, at: moment) }, state: session?.state)
    }
}


struct SessionSubtitle: View {
    let session: SessionState
    let delivery: DeliveryRequest?
    var undelivered: String?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var syncing: Bool { services.syncing.showsCatchingUp(on: session.hostID) }

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
        .animation(Motion.fade, value: syncing)
    }

    @ViewBuilder private func facts(shown: SessionShown, speaks: Bool, mark: String?, compact: Bool) -> some View {
        if mark != nil {
            AgentMark(session: session, font: Self.font)
            if !compact, speaks || undelivered != nil { Dot().foregroundStyle(palette.ink3) }
        }
        if syncing { SyncingLabel() } else if speaks { SessionShownLabel(shown: shown) }
        if let undelivered {
            if !compact, speaks { Dot().foregroundStyle(palette.failure) }
            Text(undelivered).foregroundStyle(palette.failure)
        }
        if !syncing, shown.isRunning, shown.clock != nil {
            if !compact { Dot().foregroundStyle(palette.ink3) }
            SessionElapsed(shown: shown, font: Self.font, style: compact ? .span : .header)
        }
    }

    private static let font = Typography.toolbarSubtitle
}

struct SessionShownLabel: View {
    let shown: SessionShown
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.tight) {
            #if os(iOS)
            StateDot(shown: shown, size: 6)
            #endif
            Text(shown.label).fontWeight(shown.needsYou ? .medium : nil).foregroundStyle(shown.labelTint(palette))
                .contentTransition(.opacity)
                .animation(Motion.fade, value: shown)
        }
        .sensoryFeedback(trigger: shown.status) { old, new in
            guard case .working = old else { return nil }
            return switch new {
            case .asking, .cueAsking, .awaitsReply: .warning
            case .failed, .delivery(.failed): .error
            case .idle, .unread, .resting, .ended: .impact(flexibility: .soft, intensity: 0.6)
            default: nil
            }
        }
    }
}


struct QuestionDock: View {
    let session: SessionState

    var body: some View {
        DockedCard(session.runtimeState == .known(.waitingForUser) ? session : nil) { asked in
            if let question = asked.answerableQuestion {
                QuestionCard(session: asked, question: question).id(question.promptID)
            } else {
                Callout(.asking, text: asked.question?.displayText ?? asked.detail ?? "", docked: true)
            }
        }
    }
}
