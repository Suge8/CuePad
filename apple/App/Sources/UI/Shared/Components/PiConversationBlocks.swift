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


/// Pi 的一轮回答：上方一行弱化的经过，下面全宽 Markdown，长也直接全显；长按（Mac 右键）是消息菜单（`MessageMenu`）。
struct ReplyBlock: View {
    let text: String
    let meta: PiChat.RoundNote?
    let tools: PiChatMessage.Tools?
    let session: PiSessionState
    @State private var selecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meta { ToolActivityLine(note: meta, tools: tools) }
            MarkdownText(source: text).equatable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // 整块都接长按（只靠字形判定时，按在行距、留白里会落空）
        .contentShape(.rect)
        .contextMenu { MessageActions(text: text, kind: .reply, session: session, selectText: { selecting = true }) }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: text) }
        #endif
        .transition(.entry)
    }
}


/// Pi 此刻在做什么，接在对话末尾、与回答同一列、不加底框：一行进展（动作或状态词，干活时文字有一道流光扫过；计时已在顶上一行），
/// 有子代理时下面是它们的汇总（`PiSubagentList`）。回答到了它就被回答替换。
struct LiveStatus: View {
    let session: PiSessionState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 在等子代理时，子代理那一行汇总就是进展，不再另写一行"子代理工作中"
            if session.state.isWorking, session.state != .known(.delegating) || session.subagents.isEmpty {
                // 与列表同一个转着的状态标：会话页底部这一行和列表里那一行是同一件事在动
                HStack(spacing: 8) {
                    PiStateDot(shown: PiShown(session), size: 7)
                    Text(session.detail.flatMap(PiProgress.action) ?? PiShown(session).label)
                        .font(Typography.secondary.weight(.medium))
                        .lineLimit(1).truncationMode(.middle)
                        .shimmering()
                }
            }
            PiSubagentList(agents: session.subagents)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .transition(.entry)
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
