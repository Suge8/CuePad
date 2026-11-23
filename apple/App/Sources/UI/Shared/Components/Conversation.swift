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
    @State private var roundFolds = RoundFolds()
    @State private var reveals = RevealLedger()

    var body: some View {
        let all = items
        let notes = services.settings.replyNotes(for: session.id)
        let newest = all.last { $0.role == .pi }?.id
        ChatStack(spacing: Self.spacing) {
            if fetching {
                Label("正在从 Mac 取对话…", icon: .fetching).font(Typography.meta).foregroundStyle(palette.ink3).frame(maxWidth: .infinity)
            }
            if all.allSatisfy(\.role.isOutgoing), let prompt = session.pendingPrompt ?? session.lastPrompt { RecapPreview(session: session, prompt: prompt) }
            ChatSegments(items: all, window: window, size: Self.segment) { items in
                ChatSegment(items: Array(items), session: session, highlight: highlight, newest: newest, notes: notes, swapsInPlace: swapsInPlace, opened: $opened)
                    .equatable()
            }
            ending
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.roundFolds, roundFolds)
        .environment(\.revealLedger, reveals)
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
            SessionDraft(slot: slot, session: session, messages: messages, floating: floating)
        } else {
            liveRound
        }
        #else
        liveRound
        #endif
    }

    private var floating: CGFloat { ComposerMetrics.noticeClearance(textHeight: noticeText) }

    private var liveRound: some View {
        LiveRound(session: session, messages: messages, floating: floating) {
            LiveFigure(live: FigureLive(session: session), handoff: FigureHandoff(reply: messages.last { $0.role == .known(.pi) }?.at))
        }
    }
}


#if os(macOS)
/// Mac 上开着的会话：正在说的那句逐字接在过程后面，说完（转去调工具）也留在原处，直到它落进过程或回答，没有一下空白。
/// 说着的时候与回答已落进对话、这一轮还没收尾时，角色先让开
struct SessionDraft: View {
    let slot: Bridge.Slot
    let session: SessionState
    let messages: [ChatMessage]
    let floating: CGFloat

    var body: some View {
        let draft = slot.draft, newestReply = messages.last { $0.role == .known(.pi) }
        let answered = draft?.landed(newestReply: newestReply?.at, record: newestReply?.id) ?? false
        let said = session.pendingTools?.lastSaid
        let inProcess = draft.map { draft in said.map { draft.landed(newestReply: $0.at, record: $0.record) } ?? false } ?? false
        let running = session.runtimeState.known?.isTurnRunning == true
        let shown = draft.flatMap { !answered && !inProcess && (slot.speaking || running) ? $0 : nil }
        let speaking = slot.speaking && shown != nil
        LiveRound(session: session, messages: messages, draft: shown?.text, speaking: speaking, swapsInPlace: true, floating: floating) {
            LiveFigure(live: speaking || answered && running ? nil : FigureLive(session: session), handoff: FigureHandoff(reply: newestReply?.at, speaking: speaking))
        }
    }
}
#endif


private struct ChatSegment: View, Equatable {
    let items: [ChatEntry]
    let session: SessionState
    let highlight: UUID?
    let newest: UUID?
    let notes: [ReplyNote]
    let swapsInPlace: Bool
    @Binding var opened: PreviewOpening?
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace

    init(
        items: [ChatEntry], session: SessionState, highlight: UUID?, newest: UUID?, notes: [ReplyNote], swapsInPlace: Bool, opened: Binding<PreviewOpening?>
    ) {
        self.items = items
        self.session = session
        self.swapsInPlace = swapsInPlace
        self.highlight = highlight.flatMap { id in items.contains { $0.id == id } ? id : nil }
        self.newest = newest.flatMap { id in items.contains { $0.id == id } ? id : nil }
        self.notes = notes.filter { note in items.contains { $0.id == note.entry } }
        _opened = opened
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.highlight == rhs.highlight && lhs.newest == rhs.newest && lhs.notes == rhs.notes && lhs.swapsInPlace == rhs.swapsInPlace
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
            UserBubble(stored: entry.text, look: .session, highlighted: entry.id == highlight, fromCue: entry.fromCue, fadesIn: entry.replaces == nil, said: entry.replaces) {
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
                newest: entry.id == newest, fadesIn: !swapsInPlace)
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


/// 手机会话页头的第二行只写这一页归谁、是不是最新：哪个 Agent 在做、交给 Cue 到哪一档、睡没睡、还在不在同步。
/// Agent 此刻在做什么不写在这（发送中、运行工具、用了多久、几句没送到）：对话末尾的小人（`LiveRound`）、回复框、每句话旁的送达记号已经各说了一遍，
/// 页头又只在滚到最新时才出现（`ChatFollow.showsHeader`），正是那几处都看得见的时候。一轮收尾的那一下震动仍从这里发。
struct SessionSubtitle: View {
    let session: SessionState
    let delivery: DeliveryRequest?
    var tier: CueTier?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private enum Fact: Hashable { case agent, handed(CueTier), ended, syncing }

    private var facts: [Fact] {
        var facts: [Fact] = []
        if session.agentMark != nil { facts.append(.agent) }
        if let tier, tier != .yours { facts.append(.handed(tier)) }
        if session.staysEnded(by: delivery, at: services.speech) { facts.append(.ended) }
        if services.syncing.showsCatchingUp(on: session.hostID) { facts.append(.syncing) }
        return facts
    }

    var body: some View {
        let facts = facts
        HStack(spacing: Spacing.tight) {
            ForEach(Array(facts.enumerated()), id: \.element) { index, fact in
                if index > 0 { Dot().foregroundStyle(palette.ink3) }
                switch fact {
                case .agent: AgentMark(session: session, font: Self.font)
                case .handed(let tier): Text("\(Image(Icon.cue)) \(Text(tier.title(workspace.cue.name)))").foregroundStyle(palette.signature)
                case .ended: Text("\(Image(.ended)) \(SessionShown(status: .ended).label)").foregroundStyle(palette.ink3)
                case .syncing: SyncingLabel()
                }
            }
        }
        .font(Self.font).lineLimit(1)
        .relaySpot(session: session.sessionID)
        .feelsTurnEnd(workspace.shownInHeader(session, delivery: delivery).status)
        .animation(Motion.fade, value: facts)
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
        .feelsTurnEnd(shown.status)
    }
}

extension View {
    /// 一轮收尾的那一下震动：停下等你、出错、做完各一种。
    func feelsTurnEnd(_ status: SessionShown.Status) -> some View {
        sensoryFeedback(trigger: status) { old, new in
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
