import CueStore
import SwiftUI

/// 对话还没同步过来时（很久前的会话、刚连上的会话）先放记录上的最近一轮：你说的话与 Agent 的回答；
/// 还没说过话的会话是全 App 同一种空态（吉祥物加一句怎么开始），在对话区里居中。对话到了就被它替换。
struct RecapPreview: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let prompt = session.pendingPrompt ?? session.lastPrompt {
                Text(Dotted("最近一轮", "完整对话还在同步")).font(Typography.caption).foregroundStyle(palette.ink3)
                UserBubble(stored: prompt)
                if session.pendingPrompt == nil, let reply = session.lastReply { MarkdownText(source: reply) }
            } else if !session.hasStarted, session.state != .known(.ended) {
                EmptyState(mascot: .welcome, title: "还没说过话", message: "在下面说第一句")
                    // 占满对话区（扣掉上下留白），吉祥物落在可见区中间
                    .containerRelativeFrame(.vertical) { length, _ in max(0, length - 2 * ChatLayout.edge) }
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}


/// Pi 的一轮回答：上方一块这一轮的经过（`RoundProcess`），下面全宽 Markdown，长也直接全显，批注过的地方带高亮（`notes`）；长按（Mac 右键）是消息菜单（`MessageMenu`）。
/// 新到的淡入；`fadesIn` 为 false 时（它原位换下正在说的话，见 `DraftReply`）直接出现。
struct ReplyBlock: View {
    let text: String
    /// 这一轮做了多久；没有（读不出开始时间）时不画经过那一行
    let took: String?
    let tools: PiChatMessage.Tools?
    let session: PiSessionState
    let notes: [ReplyNote]
    var fadesIn = true
    @State private var selecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let took { RoundProcess(tools: tools, ending: .took(took)) }
            MarkdownText(source: text, notes: notes).equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 整块都接长按（只靠字形判定时，按在行距、留白里会落空）
        .contentShape(.rect)
        .contextMenu { MessageActions(text: text, kind: .reply, session: session, selectText: { selecting = true }) }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: text) }
        #endif
        .transition(fadesIn ? .entry : .identity)
    }
}


/// 扩展投进会话的机器消息（`PiEnvelope`），一块信封一行旁注（`NoteLine`，`MachineNote`）：谁发来的与它交回了什么，其余收着、点开在细线下看全文（Markdown）。
/// 它在对话里落在被读到的位置，与回答同一列；不是谁对你说的话，与经过同一种样子。
struct MachineCards: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 存进对话时总是整块的信封；认不出时（别的扩展的纯文字）整条当一块，不丢字
            ForEach(Array((PiEnvelope.parse(text) ?? [PiEnvelope(name: "", body: text)]).enumerated()), id: \.offset) { _, envelope in
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
                NoteLine(symbol: note.fromFireCode ? "flame" : "puzzlepiece.extension", open: note.detail.isEmpty ? nil : open) {
                    Text(note.who).foregroundStyle(palette.ink3).fixedSize()
                    Text(note.line).foregroundStyle(note.failed ? palette.failure : palette.ink2)
                        .lineLimit(open ? nil : 2).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .disabled(note.detail.isEmpty)
            .accessibilityLabel("\(note.who)：\(note.line)")
            .accessibilityValue(note.detail.isEmpty ? "" : open ? "已展开" : "已收起")
            if open { NoteThread { MarkdownText(source: note.detail).equatable() } }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: open)
    }
}


/// 正在说的那条回答（Mac 会话页；Cue 页的在气泡里，`CueEnding`）：与说完落库后的那条同一套渲染、同一个位置，`header` 占着那条上方经过那一行的位置（同样高，见 `RoundProcess`），
/// 所以落库时原位换下、正文不动。开始出字时淡入；换下与清掉都是直接拿掉——落库的那条同一帧直接出现（不淡入），两份不会叠着出现。
struct DraftReply<Header: View>: View {
    let text: String
    @ViewBuilder let header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            MarkdownText(source: text).equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.asymmetric(insertion: .entry, removal: .identity))
    }
}


/// Pi 此刻在做什么，接在对话末尾、与回答同一列：这一轮的经过（`RoundProcess`，已做完的几步收成一行，
/// 正在跑的那一步实时展开；计时已在顶上一行），有子代理时下面是它们的汇总（`PiSubagentList`）。回答到了它就被回答替换；
/// 怎么出现、怎么拿掉由放它的地方定。Mac 上正在说的话出字时这一块是草稿的标题（`SessionDraft`，`ending(of:speaking:)`）。
struct LiveStatus: View {
    let session: PiSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let ending = Self.ending(of: session, speaking: false) {
                RoundProcess(tools: session.pendingTools, ending: ending)
            }
            PiSubagentList(agents: session.subagents)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// 经过那一行的结尾。正在说话时总有（占着说完后那条回答上方的位置，状态可能先于草稿落库变成歇着）；
    /// 其余没在跑一轮时没有。在等子代理时子代理那一行汇总就是进展，没做过步骤就不另写一块"子代理工作中"。
    static func ending(of session: PiSessionState, speaking: Bool) -> RoundProcess.Ending? {
        if speaking { return .speaking }
        let shown = PiShown(session)
        let delegating = session.state == .known(.delegating) && !session.subagents.isEmpty
        guard session.state.isWorking, !delegating || session.pendingTools != nil else { return nil }
        guard !delegating else { return .live(shown, doing: shown.label, step: nil) }
        let tool = session.state == .known(.tool) ? session.detail?.components(separatedBy: PiProgress.detailSeparator).first : nil
        return .live(shown, doing: session.detail.flatMap(PiProgress.action) ?? shown.label, step: RoundProcess.symbol(tool: tool))
    }
}



extension View {
    /// 进行中的文字：底色是淡墨，一道墨色的光从左往右反复扫过（`LoopLayer`）；减弱动态效果时是静止的次要色。
    func shimmering() -> some View { modifier(Shimmer()) }
}


struct Shimmer: ViewModifier {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content.foregroundStyle(palette.ink2)
        } else {
            content
                .foregroundStyle(palette.ink3)
                .overlay { LoopLayer(kind: .sheen, color: palette.ink).mask { content } }
        }
    }
}
