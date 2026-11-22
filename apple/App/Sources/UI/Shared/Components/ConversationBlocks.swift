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
            RoundProcess(tools: tools, took: took, session: session, message: id, fadesIn: fadesIn)
            MarkdownText(source: text, notes: notes).equatable()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .contextMenu { menu }
                .padding(.top, tools?.items.contains { $0.kind == .said } == true ? RoundProcess.apart : 0)
        }
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


/// 在跑的一轮：过程接在对话末尾，Mac 上正在说的那句跟在最后，子代理与角色在下面。这一轮做完，对话里的回答（`ReplyBlock`）在原处接上同样的排法。
/// 摆不摆过程只看库里这一轮还开着没有（`pendingTools`），不看 Agent 此刻的状态：Mac 上状态先歇下，回答过一会儿才读进库。
/// 手机上这一轮的状态与对话分两条通道同步，状态走快的那条。状态先到、清掉了过程时，接着摆刚才那份（`held`），
/// 直到这一轮的结局进了对话（`Chat.awaiting`）：回答按身份认（`Chat.landed`，过程里的项或升成回答的那句话），
/// "已停下"按收尾的时刻（`answeredAt`）认；空着收的尾、又来了新的一句、或另一轮已经收尾（回答摘要变了）都不再接着摆。
/// 回答先到时，已经落进回答的那份不再摆
struct LiveRound<Below: View>: View {
    let session: SessionState
    let messages: [ChatMessage]
    var draft: String?
    var swapsInPlace = false
    let floating: CGFloat
    @ViewBuilder let below: Below
    @State private var held: (tools: ChatMessage.Tools, reply: String?)?

    var body: some View {
        let open = session.pendingTools.flatMap { Chat.landed($0, in: messages.last { $0.role == .known(.pi) }) ? nil : $0 }
        let shown = open ?? held.flatMap { Chat.awaiting($0.tools, endedWith: $0.reply, session: session, messages: messages) ? $0.tools : nil }
        VStack(alignment: .leading, spacing: Conversation.spacing) {
            RoundProcess(tools: shown, draft: draft, session: session, fadesIn: !swapsInPlace)
                .transition(swapsInPlace ? .asymmetric(insertion: .entry, removal: .identity) : .entry)
            ChatLiveSlot(spacing: Conversation.spacing, floating: floating) {
                VStack(alignment: .leading, spacing: Spacing.item) {
                    SubagentList(agents: session.runtimeSubagents)
                    below
                }
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: session.pendingTools) { old, new in held = new == nil ? old.map { (tools: $0, reply: session.lastReply) } : nil }
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
