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


/// 新到的淡入；`fadesIn` 为 false 时（它原位换下正在说的话，见 `DraftReply`）直接出现。
struct ReplyBlock: View {
    let id: UUID
    let text: String
    let took: String?
    let tools: ChatMessage.Tools?
    let session: SessionState
    let notes: [ReplyNote]
    var latest = false
    var fadesIn = true
    #if os(iOS)
    @Environment(\.replyText) private var replyText
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if let took { RoundProcess(tools: tools, ending: .took(took), session: session, open: latest) }
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
            // 存进对话时总是整块的信封；认不出时（别的扩展的纯文字）整条当一块，不丢字
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                NoteLine(icon: note.fromFireCode ? .fireCode : .extensionNote, open: note.detail.isEmpty ? nil : open) {
                    Text(note.who).foregroundStyle(palette.ink3).fixedSize()
                    Text(note.line).foregroundStyle(note.failed ? palette.failure : palette.ink2)
                        .lineLimit(open ? nil : 2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(PressStyle())
            // 没有全文可看时只是不接点按，不停用：停用的按钮 iOS 整块压淡
            .allowsHitTesting(!note.detail.isEmpty)
            .accessibilityLabel("\(note.who)：\(note.line)")
            .accessibilityExpanded(note.detail.isEmpty ? nil : open)
            if open { NoteThread { MarkdownText(source: note.detail).equatable() } }
        }
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: open)
    }
}


/// `header` 占着说完后那条回答上方经过那一行的位置（同样高，见 `RoundProcess`），所以落库时原位换下、正文不动。换下与清掉都是直接拿掉——落库的那条同一帧直接出现（不淡入），两份不会叠着出现。
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

    /// 正在说话时总有（占着说完后那条回答上方的位置，状态可能先于草稿落库变成歇着）；在等子代理时子代理那一行汇总就是进展，没做过步骤就不另写一块"子代理工作中"。
    static func ending(of session: SessionState, speaking: Bool) -> RoundProcess.Ending? {
        if speaking { return .speaking }
        let shown = SessionShown(session)
        let delegating = session.state == .known(.delegating) && !session.runtimeSubagents.isEmpty
        guard session.runtimeState.isWorking, !delegating || session.pendingTools != nil else { return nil }
        guard !delegating else { return .live(shown, doing: shown.label, step: nil) }
        let tool = session.state == .known(.tool) ? session.detail?.components(separatedBy: SessionState.detailSeparator).first : nil
        return .live(shown, doing: session.detail.flatMap(SessionProgress.action) ?? shown.label, step: RoundProcess.icon(tool: tool))
    }
}



extension View {
    func shimmering() -> some View { modifier(Shimmer()) }
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
