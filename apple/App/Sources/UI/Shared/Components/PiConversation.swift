import CueStore
import CueText
import SwiftUI

/// 会话页的对话（iOS 会话页、Mac 会话详情共用）：你的话右侧墨色气泡，Pi 的回答左侧全宽 Markdown（不折叠），
/// 每轮回答上方一行这一轮的经过；你发出还没进对话的话接在末尾，气泡下写送达情况，失败的可重发；
/// Pi 在处理时末尾一个"Pi 正在处理…"小气泡（当前动作与计时），出错时末尾写原因。滚动与输入框由平台放。
/// 减弱动态效果下也只有淡入淡出。
struct PiConversation: View {
    let session: PiSessionState
    let messages: [PiChatMessage]
    var deliveries: [DeliveryRequest] = []
    @Environment(\.palette) private var palette

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 18) {
            ForEach(PiChat.entries(messages)) { entry in
                if entry.isUser { UserBubble(text: entry.text) } else { ReplyBlock(text: entry.text, meta: entry.meta) }
            }
            ForEach(PiChat.outgoing(deliveries, messages: messages)) { request in OutgoingBubble(request: request, session: session) }
            if session.state.isWorking { WorkingBubble(session: session) }
            if session.state == .known(.error) {
                Callout(tint: palette.failure, title: "出错", text: session.detail ?? "Mac 没有说明原因", prominent: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.quick, value: messages.map(\.id))
        .animation(Motion.quick, value: deliveries.map(\.status))
        .animation(Motion.quick, value: session.state)
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
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            PiStateDot(state: session.state, size: 6)
            // 所在太长时截断（最宽 `placeWidth`），状态与计时不截；整行按内容宽，不被导航栏挤
            if let place = PiPlace.name(of: session, project: project) {
                Text("\(place) ·").foregroundStyle(palette.ink3).lineLimit(1)
                    .frame(maxWidth: Self.placeWidth, alignment: .leading)
            }
            Group {
                Text(session.state.label).fontWeight(.medium).foregroundStyle(session.state.tint(palette))
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

/// 子代理一行小标签：状态标 + 名字 + 在干什么，图标与颜色同会话状态那一套。
struct PiSubagentChips: View {
    let subagents: [PiSubagentState]
    @Environment(\.palette) private var palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Array(subagents.enumerated()), id: \.offset) { _, agent in
                    HStack(spacing: 4) {
                        PiStateDot(state: agent.workState, size: 6)
                        Text(agent.name).foregroundStyle(palette.ink)
                        Text(agent.activityLabel).foregroundStyle(agent.workState.tint(palette))
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.caption)
        }
    }
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
                Callout(
                    tint: palette.attention, title: "等你确认", text: session.question?.displayText ?? session.detail ?? "",
                    prominent: true, note: "这个问题要在 Mac 上回答")
            }
        }
    }
}

/// 你的一句话：右侧墨色气泡，最宽到四分之三。
private struct UserBubble: View {
    let text: String
    var dimmed = false
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(.body).foregroundStyle(palette.onAccent)
            .textSelection(.enabled)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(palette.accent.opacity(dimmed ? 0.7 : 1), in: .rect(cornerRadius: 18, style: .continuous))
            .containerRelativeFrame(.horizontal, alignment: .trailing) { width, _ in width * 0.78 }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .transition(.opacity)
    }
}

/// Pi 的一轮回答：上方一行弱化的经过，下面全宽 Markdown，长也直接全显。
private struct ReplyBlock: View {
    let text: String
    let meta: String?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let meta { Text(meta).font(.caption).foregroundStyle(palette.ink3) }
            MarkdownText(source: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
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
                    if let reason = request.resultDetail { Text(reason).font(.caption).foregroundStyle(palette.failure).lineLimit(2) }
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
        .transition(.opacity)
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
                old.content, to: session, mode: old.mode.known ?? .followUp, card: old.cardID, task: old.taskID)
            try await workspace.services.store.deleteDelivery(old.id)
        }
    }

    private func remove() {
        let id = request.id
        workspace.perform { try await $0.deleteDelivery(id) }
    }
}

/// Pi 在处理：左侧一个小气泡，写当前动作与这段处理的计时；回答到了它就被回答替换。
private struct WorkingBubble: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Pi 正在处理…").font(.subheadline.weight(.medium)).foregroundStyle(palette.ink2)
            }
            HStack(spacing: 4) {
                if let action = session.detail.flatMap(PiProgress.action) {
                    Text(action).font(session.detailIsCode ? .caption.monospaced() : .caption).lineLimit(1)
                    Text("·")
                }
                PiElapsed(session: session, font: .caption)
            }
            .font(.caption).foregroundStyle(palette.ink3)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(palette.paper, in: .rect(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(palette.hair))
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }
}
