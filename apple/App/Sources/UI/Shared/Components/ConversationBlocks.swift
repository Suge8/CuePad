import CueStore
import SwiftUI

struct RecapPreview: View {
    let session: SessionState
    let prompt: String
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Conversation.spacing) {
            Text("最近一轮，完整对话还在同步").font(Typography.caption).foregroundStyle(palette.ink3)
            UserBubble(stored: prompt, look: .session) {}
            if session.pendingPrompt == nil, let reply = session.lastReply { MarkdownText(source: reply) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 你发出第一句（送没送达都算）就淡掉：叠层只改透明度，不靠滚动内容里的移除过渡（滚动区里的移除不播淡出，一帧切掉），也不把新气泡顶在下面。
struct BlankChat: View {
    let shown: Bool
    let readingWidth: CGFloat
    let inset: CGFloat
    @Environment(\.chatBottomInset) private var bottomInset

    var body: some View {
        GeometryReader { proxy in
            EmptyState(mascot: .welcome, title: "还没说过话", message: "在下面说第一句")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, ChatLayout.margin(proxy.size.width, readingWidth: readingWidth, inset: inset))
        }
            .padding(.bottom, bottomInset)
            .opacity(shown ? 1 : 0)
            .animation(Motion.fade, value: shown)
            .allowsHitTesting(false)
            .readerHidden(!shown)
    }
}


struct ReplyBlock: View {
    let id: UUID
    let text: String
    let took: String?
    let tools: ChatMessage.Tools?
    let session: SessionState
    let notes: [ReplyNote]
    var fadesIn = true
    #if os(iOS)
    @Environment(\.replyText) private var replyText
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if let took { RoundProcess(tools: tools, ending: .took(took), session: session, message: id) }
            MarkdownText(source: text, notes: notes).equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .contextMenu { menu }
        .transition(fadesIn ? .entry : .identity)
    }

    private var menu: some View {
        #if os(iOS)
        MessageActions(
            text: text, kind: .reply, session: session,
            selectText: replyText.map { open in { open(id, .select) } }, annotate: replyText.map { open in { open(id, .annotate) } })
        #else
        MessageActions(text: text, kind: .reply, session: session)
        #endif
    }
}


struct MachineCards: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            ForEach(Array((MessageEnvelope.parse(text) ?? [MessageEnvelope(name: "", body: text)]).enumerated()), id: \.offset) { _, envelope in
                MachineCard(note: MachineNote(envelope))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.entry)
    }
}

private struct MachineCard: View {
    let note: MachineNote
    @Environment(\.palette) private var palette
    @State private var open = false

    var body: some View {
        Fold(open: $open, toggles: !note.detail.isEmpty) {
            NoteLine(icon: note.fromFireCode ? .fireCode : .extensionNote, open: note.detail.isEmpty ? nil : open) {
                Text(note.who).foregroundStyle(palette.ink3).fixedSize()
                Text(note.line).foregroundStyle(note.failed ? palette.failure : palette.ink2)
                    .lineLimit(open ? nil : 2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(note.who)：\(note.line)")
        } content: {
            if open { NoteThread { MarkdownText(source: note.detail).equatable() } }
        }
    }
}


struct DraftReply<Header: View>: View {
    let text: String
    @ViewBuilder let header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            header
            MarkdownText(source: text).equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.asymmetric(insertion: .entry, removal: .identity))
    }
}


struct LiveStatus: View {
    let session: SessionState

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if let ending = Self.ending(of: session, speaking: false) {
                RoundProcess(tools: session.pendingTools, ending: ending, session: session)
            }
            SubagentList(agents: session.runtimeSubagents)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    static func ending(of session: SessionState, speaking: Bool) -> RoundProcess.Ending? {
        if speaking { return .speaking }
        let delegating = session.state == .known(.delegating) && !session.runtimeSubagents.isEmpty
        guard session.runtimeState.isWorking, !delegating || session.pendingTools != nil else { return nil }
        return .running
    }
}



extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
}

struct DoingLine: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text(text).shimmering().id(text).transition(reduceMotion ? .handOff : .rise)
        }
        .animation(Motion.nudge, value: text)
    }
}

extension AnyTransition {
    static let rise = AnyTransition.asymmetric(
        insertion: .modifier(active: Rise(away: true), identity: Rise(away: false)).animation(Motion.nudge.delay(Motion.Fade.yield)),
        removal: .opacity.animation(Motion.yield))
}

private struct Rise: ViewModifier {
    let away: Bool

    func body(content: Content) -> some View {
        content.offset(y: away ? 6 : 0).blur(radius: away ? 3 : 0).opacity(away ? 0 : 1)
    }
}


struct Shimmer: ViewModifier {
    @Environment(\.palette) private var palette
    @LoopsPlay private var sweeps

    func body(content: Content) -> some View {
        if sweeps {
            content
                .foregroundStyle(palette.ink3)
                .overlay { LoopLayer(kind: .sheen, color: palette.ink).mask { content } }
        } else {
            content.foregroundStyle(palette.ink2)
        }
    }
}
