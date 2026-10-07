import CueStore
import CueText
import SwiftUI

/// 会话页的对话（iOS 会话页、Mac 会话详情共用）：你的话右侧墨色气泡，Pi 的回答左侧全宽 Markdown（不折叠），
/// 每轮回答上方一行这一轮的经过；你发出还没进对话的话接在末尾，气泡下写送达情况，失败的可重发；
/// Pi 在处理时末尾一行流光的进展（当前动作；计时在顶上一行），有子代理时下面逐个列出它们此刻的状态；出错时末尾写原因。滚动与输入框由平台放。
/// 减弱动态效果下也只有淡入淡出。
struct PiConversation: View {
    let session: PiSessionState
    let messages: [PiChatMessage]
    var deliveries: [DeliveryRequest] = []
    @Environment(\.palette) private var palette
    @Environment(\.chatInverted) private var inverted
    @Environment(\.chatBottomSpace) private var bottomSpace
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        // 懒加载：只排看得见的几条（整段排开时，长对话的每条回答都在推入那一刻排版、栅格化，转场的前一百多毫秒画不出来）。
        // 在倒置的滚动区里（iOS）按新到旧给出，懒加载从最新那条起排
        let entries = PiChat.entries(messages)
        let outgoing = PiChat.outgoing(deliveries, messages: messages)
        LazyVStack(alignment: .leading, spacing: Self.spacing) {
            if inverted {
                // 让出底下回复框与键盘占的高（`ChatScroll`）；它和第一条之间本有一份行距，扣掉
                Color.clear.frame(height: max(0, bottomSpace - Self.spacing)).accessibilityHidden(true)
                // 读屏仍按先后读：越早的越先
                ending.chatRow().accessibilitySortPriority(-Double(entries.count + outgoing.count))
                ForEach(Array(outgoing.enumerated()).reversed(), id: \.element.id) { index, request in
                    OutgoingBubble(request: request, session: session).chatRow().accessibilitySortPriority(-Double(entries.count + index))
                }
                ForEach(Array(entries.enumerated()).reversed(), id: \.element.id) { index, entry in
                    row(entry).chatRow().accessibilitySortPriority(-Double(index))
                }
            } else {
                ForEach(entries) { entry in row(entry) }
                ForEach(outgoing) { request in OutgoingBubble(request: request, session: session) }
                ending
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static var spacing: CGFloat { 18 }

    @ViewBuilder private func row(_ entry: PiChatEntry) -> some View {
        if entry.isUser { UserBubble(text: entry.text, highlighted: entry.id == highlight) } else { ReplyBlock(text: entry.text, meta: entry.meta, session: session) }
    }

    /// 对话末尾：处理中的进展（带子代理）、出错的原因。
    @ViewBuilder private var ending: some View {
        if session.state.isWorking || !session.subagents.isEmpty { LiveStatus(session: session) }
        if session.state == .known(.error) {
            Callout(tint: palette.failure, symbol: "exclamationmark.circle.fill", text: session.detail ?? "Mac 没有说明原因")
        }
    }
}

extension PiConversation {
    /// 对话里"有新内容"的标志（滚动跟随用，见 `ChatScroll`）：多了消息、发出的话或它的送达情况变了、开始或结束处理、出错。
    struct FollowKey: Equatable {
        var messages: Int
        var outgoing: [Open<DeliveryStatus>]
        var state: Open<PiWorkState>?
    }

    static func followKey(session: PiSessionState?, messages: [PiChatMessage], deliveries: [DeliveryRequest]) -> FollowKey {
        FollowKey(messages: messages.count, outgoing: PiChat.outgoing(deliveries, messages: messages).map(\.status), state: session?.state)
    }
}

/// 会话名下的一行小字：状态标、所在、状态词（带色）、计时；Mac 后台托管的再写"后台"。
struct PiSessionSubtitle: View {
    let session: PiSessionState
    let project: Project?
    /// 发给它的最近一条投送请求：话还在路上时状态先写路上到哪了（`PiDelivery`）。
    let delivery: DeliveryRequest?
    @Environment(\.palette) private var palette

    var body: some View {
        // 正在看的会话没有"有新回复"
        let shown = PiShown(state: session.state, delivery: PiDelivery.phase(of: delivery, for: session))
        HStack(spacing: 4) {
            PiStateDot(shown: shown, size: 6)
            // 所在太长时截断（最宽 `placeWidth`），状态与计时不截；整行按内容宽，不被导航栏挤
            if let place = PiPlace.name(of: session, project: project) {
                Text("\(place) ·").foregroundStyle(palette.ink3).lineLimit(1)
                    .frame(maxWidth: Self.placeWidth, alignment: .leading)
            }
            Group {
                Text(shown.label).fontWeight(.medium).foregroundStyle(shown.tint(palette))
                    .contentTransition(.opacity)
                    .animation(Motion.quick, value: shown)
                if session.hosted, session.state != .known(.ended) { Text("· 后台").foregroundStyle(palette.ink3) }
                Text("·").foregroundStyle(palette.ink3)
                PiElapsed(session: session, font: .caption)
            }
            .fixedSize()
        }
        .font(.caption)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private static let placeWidth: CGFloat = 140
}

/// 等你确认时固定在输入框上方的问题：能从这里答的是问题卡（选项一点即答，答完随问题清空而消失），
/// 只能在 Mac 上答的写明原文与去处。
struct PiQuestionDock: View {
    let session: PiSessionState
    var deliveries: [DeliveryRequest] = []
    @Environment(\.palette) private var palette

    var body: some View {
        if session.state == .known(.waitingForUser) {
            if let question = session.question, question.isAnswerable {
                QuestionCard(session: session, question: question, deliveries: deliveries).id(question.promptID)
            } else {
                // 去哪答写在回复框的位置上（各平台不同），这里只放问题
                Callout(tint: palette.attention, symbol: "questionmark.circle.fill", text: session.question?.displayText ?? session.detail ?? "", prominent: true)
            }
        }
    }
}

private extension AnyTransition {
    /// 对话里一条出现或消失：只淡入淡出，动画随过渡自带。不给整段对话挂动画：倒置的滚动区里新的一条加在逻辑顶端，
    /// 其余各行的位移若也跟着动画，正在读的那段会先被推走再滑回来
    static let entry = AnyTransition.opacity.animation(Motion.quick)
}

/// 你的一句话：右侧气泡（颜色是 `Palette.bubble`），最宽到四分之三；还在路上的整颗变淡。
private struct UserBubble: View {
    let text: String
    var dimmed = false
    var highlighted = false
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        Text(text)
            .font(.body).foregroundStyle(palette.onBubble)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(palette.bubble, in: shape)
            .overlay(shape.strokeBorder(highlighted ? palette.accent : palette.bubbleEdge, lineWidth: highlighted ? 2 : 1))
            .animation(Motion.quick, value: highlighted)
            .opacity(dimmed ? 0.7 : 1)
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.78 }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.entry)
    }
}

/// Pi 的一轮回答：上方一行弱化的经过，下面全宽 Markdown，长也直接全显；长按（Mac 右键）可以存为卡片，进会话所属的项目。
private struct ReplyBlock: View {
    let text: String
    let meta: String?
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let meta { Text(meta).font(.caption).foregroundStyle(palette.ink3) }
            MarkdownText(source: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button("存为灵感", systemImage: "square.and.arrow.down") { workspace.attempt { try await workspace.saveReply(text, of: session) } }
        }
        .transition(.entry)
    }
}

/// 你发出、还没进对话的话：你的气泡，下面送达情况；没能送达时写原因，可以重发或移除。
private struct OutgoingBubble: View {
    let request: DeliveryRequest
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private var failed: Bool { request.status == .known(.failed) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            UserBubble(text: text, dimmed: !failed)
            HStack(spacing: 10) {
                if failed {
                    if let reason = request.failure { Text(reason).font(.caption).foregroundStyle(palette.failure).lineLimit(2) }
                    // 送不到 Mac 时也露出来（停用），看得出能重发
                    Button("重发", action: retry).font(.caption.weight(.semibold)).disabled(!workspace.services.reachesPiHost)
                } else {
                    // 发给已结束的会话：Mac 先在后台把它唤醒再送达
                    DeliveryStatusLabel(request: request, waking: session.state == .known(.ended)).font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            if failed { Button("重发", systemImage: "arrow.clockwise", action: retry).disabled(!workspace.services.reachesPiHost) }
            Button("移除", systemImage: "xmark", role: .destructive, action: remove)
        }
        .transition(.entry)
    }

    /// 带卡片的话写卡片标题与图片数，不露存储格式。
    private var text: String {
        let card = CardText(request.content)
        guard !card.images.isEmpty else { return request.content }
        return [card.title.isEmpty ? nil : card.title, "\(card.images.count) 张图片"].compactMap { $0 }.joined(separator: " · ")
    }

    /// 同样的内容与方式再发一次；新请求写成后移除这条失败的。
    private func retry() {
        let old = request, session = session
        workspace.attempt {
            _ = try await workspace.services.requestMacDelivery(
                old.content, to: session, mode: old.mode.known ?? .followUp, card: old.cardID)
            try await workspace.services.store.deleteDelivery(old.id)
        }
    }

    private func remove() {
        let id = request.id
        workspace.perform { try await $0.deleteDelivery(id) }
    }
}

/// Pi 此刻在做什么，接在对话末尾、与回答同一列、不加底框：一行进展（动作或状态词，干活时文字有一道流光扫过；计时已在顶上一行），
/// 有子代理时下面每个一行：状态标、名字、状态词。回答到了它就被回答替换。
private struct LiveStatus: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if session.state.isWorking {
                Text(session.detail.flatMap(PiProgress.action) ?? session.state.label)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                    .shimmering()
            }
            ForEach(Array(session.subagents.enumerated()), id: \.offset) { _, agent in
                HStack(spacing: 6) {
                    PiStateDot(state: agent.workState, size: 7)
                    Text(agent.name).foregroundStyle(palette.ink2).lineLimit(1)
                    Text(agent.activityLabel).foregroundStyle(agent.workState.tint(palette))
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .transition(.entry)
    }
}

private extension View {
    /// 进行中的文字：底色是淡墨，一道墨色的光从左往右反复扫过；减弱动态效果时是静止的次要色。
    func shimmering() -> some View { modifier(Shimmer()) }
}

private struct Shimmer: ViewModifier {
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var swept = false

    func body(content: Content) -> some View {
        if reduceMotion {
            content.foregroundStyle(palette.ink2)
        } else {
            content
                .foregroundStyle(palette.ink3)
                .overlay {
                    content.foregroundStyle(palette.ink).mask {
                        GeometryReader { proxy in
                            let band = max(proxy.size.width * 0.4, 48)
                            LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: swept ? proxy.size.width : -band)
                        }
                    }
                }
                // 渲染端插值：整段循环不触发重算视图
                .onAppear { withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { swept = true } }
        }
    }
}
