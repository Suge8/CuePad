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


/// Pi 的一轮回答：上方一行弱化的经过，下面全宽 Markdown，长也直接全显，批注过的地方带高亮（`notes`）；长按（Mac 右键）是消息菜单（`MessageMenu`）。
/// 新到的淡入；`fadesIn` 为 false 时（它原位换下正在说的话，见 `DraftReply`）直接出现。
struct ReplyBlock: View {
    let text: String
    let meta: PiChat.RoundNote?
    let tools: PiChatMessage.Tools?
    let session: PiSessionState
    let notes: [ReplyNote]
    var fadesIn = true
    @State private var selecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meta { ToolActivityLine(note: meta, tools: tools) }
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


/// 正在说的那条回答（Mac：会话页、Cue 页）：与说完落库后的那条同一套渲染、同一个位置，`header` 占着那条上方注脚的位置（同样高，见 `roundNoteFrame`），
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


/// 会话里正在说的话上方那一行：占着说完后注脚（`ToolActivityLine`）的位置与外形，写"输出中"（`PiShown.speaking`）。
struct DraftProgress: View {
    let session: PiSessionState

    var body: some View {
        let shown = PiShown(session).speaking(true)
        HStack(spacing: 6) {
            PiStateDot(shown: shown, size: 6)
            Text(session.detail.flatMap(PiProgress.action) ?? shown.label).lineLimit(1).shimmering()
        }
        .roundNoteLine()
        .roundNoteFrame()
    }
}


/// Pi 此刻在做什么，接在对话末尾、与回答同一列、不加底框：一行进展（动作或状态词，干活时文字有一道流光扫过；计时已在顶上一行），
/// 有子代理时下面是它们的汇总（`PiSubagentList`）。回答到了它就被回答替换；怎么出现、怎么拿掉由放它的地方定。
struct LiveStatus: View {
    let session: PiSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 在等子代理时，子代理那一行汇总就是进展，不再另写一行"子代理工作中"
            if session.state.isWorking, session.state != .known(.delegating) || session.subagents.isEmpty {
                LiveLine(shown: PiShown(session), text: session.detail.flatMap(PiProgress.action) ?? PiShown(session).label)
            }
            PiSubagentList(agents: session.subagents)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}


/// 在做事时对话末尾那一行（会话页与 Cue 页同一个）：与列表同一个转着的状态标（底部这一行和列表里那一行是同一件事在动），
/// 后面是当前动作（没有动作时是状态词），文字上一道流光。
struct LiveLine: View {
    let shown: PiShown
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            PiStateDot(shown: shown, size: 7)
            Text(text)
                .font(Typography.secondary.weight(.medium))
                .lineLimit(1).truncationMode(.middle)
                .shimmering()
        }
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
