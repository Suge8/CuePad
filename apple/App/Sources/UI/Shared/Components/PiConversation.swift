import CueStore
import SwiftUI


/// 会话页的对话（iOS 会话页、Mac 会话页共用）：你的话右侧墨色气泡，Pi 的回答左侧全宽 Markdown（不折叠），
/// 每轮回答上方一行这一轮的经过；你发出还没进对话的话接在末尾，气泡下写送达情况，失败的可重发；
/// Pi 在处理时末尾一行流光的进展（当前动作；计时在顶上一行），有子代理时下面逐个列出它们此刻的状态；出错时末尾写原因。滚动与输入框由平台放。
/// 减弱动态效果下也只有淡入淡出。
struct PiConversation: View {
    let session: PiSessionState
    let messages: [PiChatMessage]
    var previews: [PiPreview] = []
    var deliveries: [DeliveryRequest] = []
    /// 至少排开最近这么多条（不用懒加载栈，见 `ChatScroll`）；更早的由 `showEarlier` 再排开一段。
    let window: Int
    var showEarlier: () -> Void = {}
    @Environment(\.palette) private var palette
    @Environment(\.chatHighlight) private var highlight
    @State private var opened: PiPreview?

    var body: some View {
        let all = ChatItem.of(PiChat.entries(messages, previews: previews))
        let first = Self.firstSegment(count: all.count, window: window)
        VStack(alignment: .leading, spacing: Self.spacing) {
            if first > 0 {
                EarlierRow(hidden: first * Self.segment, action: showEarlier)
            }
            if all.isEmpty { RecapPreview(session: session) }
            // 一段一段排，每段只按内容比较：上面再排开一段、下面来了新消息时，没变的段不重算也不重排，
            // 系统直接用上次量好的尺寸（整列一起排时，每排开一段都把已排开的全部重量一遍，长对话里一次几百毫秒）
            ForEach(first..<Self.segments(all.count), id: \.self) { index in
                ChatSegment(
                    items: Array(all[(index * Self.segment)..<min((index + 1) * Self.segment, all.count)]), session: session,
                    highlight: highlight, opened: $opened
                )
                .equatable()
            }
            ForEach(PiChat.outgoing(deliveries, messages: messages)) { request in OutgoingBubble(request: request, session: session) }
            ending
        }
        // 刻度滑条按 id 跳到你的某句话（`ChatFollow.jump`）：滚动区只认滚动目标布局里的行
        .scrollTargetLayout()
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(iOS)
        // 手机上长按出的是消息菜单，挑字走菜单里的"选择文本"：对话里的字不开行内选择，每行少建一套文字交互。
        // 挂在弹出预览之内：从这里打开的文件预览照常可选
        .environment(\.inlineTextSelection, false)
        #endif
        .previewPresenter($opened)
        .task(id: previews.map(\.id)) {
            if let title = DebugHooks.preset.openPreview { opened = previews.first { $0.title == title } }
        }
    }

    static var spacing: CGFloat { 16 }
    /// 最初至少排开几条；一段几条（每次再排开一段）。段按从最早那条起的位置切，排开更早的只是在上面多显示一段，已有的段不变。
    static let firstWindow = 4, segment = 10

    static func segments(_ count: Int) -> Int { (count + segment - 1) / segment }

    /// 排开最近 `window` 条要从第几段起。
    static func firstSegment(count: Int, window: Int) -> Int { max(0, count - window) / segment }

    /// 对话末尾：处理中的进展（带子代理）、出错的原因。
    @ViewBuilder private var ending: some View {
        if session.state.isWorking || !session.subagents.isEmpty { LiveStatus(session: session) }
        if session.state == .known(.error) {
            Callout(tint: palette.failure, symbol: "exclamationmark.circle.fill", text: session.detail ?? "Mac 没有说明原因")
        }
    }
}


/// 对话里的一段（`PiConversation.segment` 条）。只按内容比较：同样的几条、描圈的那条（只看本段里的）、同一个会话就不重算。
private struct ChatSegment: View, Equatable {
    let items: [ChatItem]
    let session: PiSessionState
    let highlight: UUID?
    @Binding var opened: PiPreview?
    @Environment(\.palette) private var palette

    init(items: [ChatItem], session: PiSessionState, highlight: UUID?, opened: Binding<PiPreview?>) {
        self.items = items
        self.session = session
        self.highlight = highlight.flatMap { id in items.contains { $0.id == id } ? id : nil }
        _opened = opened
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.highlight == rhs.highlight && lhs.session.id == rhs.session.id && lhs.session.projectID == rhs.session.projectID
    }

    private static var turnGap: CGFloat { 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: PiConversation.spacing) {
            ForEach(items) { item in row(item) }
        }
    }

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
        switch item {
        case .previews(let group): PreviewGroup(previews: group.compactMap(\.preview)) { opened = $0 }
        case .entry(let entry): row(entry)
        }
    }

    @ViewBuilder private func row(_ entry: PiChatEntry) -> some View {
        switch entry.role {
        case .user:
            UserBubble(text: Dotted(entry.text), highlighted: entry.id == highlight) {
                MessageActions(text: entry.text, kind: .mine, session: session)
            }
                // 你的话开始新的一轮：轮与轮之间比轮内（你的话与它的回答）松一截
                .padding(.top, Self.turnGap)
        case .pi:
            ReplyBlock(text: entry.text, meta: entry.meta, tools: entry.tools, session: session)
        case .system:
            // 会话文件里的系统记录（压缩）：居中一行小字，不是谁说的话
            Text(entry.text).font(Typography.meta).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        case .preview:
            if let preview = entry.preview { PreviewGroup(previews: [preview]) { opened = $0 } }
        }
    }
}


/// 排开的最上面一行：还有更早的对话。往上翻快到这里时会自动再排开一段（`ChatFollow.nearOldest`），点它（读屏）也能排开。
struct EarlierRow: View {
    let hidden: Int
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button("更早的 \(min(hidden, PiConversation.segment)) 条", action: action)
            .font(Typography.caption.weight(.semibold)).foregroundStyle(palette.ink3)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 28)
    }
}


extension PiConversation {
    /// 要跳到 `id` 那一条（刻度滑条）时至少要排开最近几条（`window`）。
    static func window(reaching id: UUID, messages: [PiChatMessage], previews: [PiPreview]) -> Int? {
        let items = ChatItem.of(PiChat.entries(messages, previews: previews))
        return items.firstIndex { $0.id == id }.map { items.count - $0 }
    }

    /// 对话里"有新内容"的标志（滚动跟随用，见 `ChatScroll`）：多了消息、发出的话或它的送达情况变了、开始或结束处理、出错。
    struct FollowKey: Equatable {
        var messages: Int
        var previews: Int
        var outgoing: [Open<DeliveryStatus>]
        var state: Open<PiWorkState>?
    }

    static func followKey(session: PiSessionState?, messages: [PiChatMessage], previews: [PiPreview] = [], deliveries: [DeliveryRequest]) -> FollowKey {
        FollowKey(messages: messages.count, previews: previews.count, outgoing: PiChat.outgoing(deliveries, messages: messages).map(\.status), state: session?.state)
    }
}


/// 会话名下的一行小字：状态标与状态词（带色），有没送到的话时接一句胭脂的"N 句没送到"（`PiChat.undeliveredNote`），
/// 后面淡一级的计时。所在与"后台"不放在这里（顶栏一行只说一件事），写在"⋯"菜单的最上面（`PiPlace.menuTitle`）。
struct PiSessionSubtitle: View {
    let session: PiSessionState
    var undelivered: String?
    @Environment(\.palette) private var palette

    var body: some View {
        // 顶栏只说会话自己的状态：你的话到哪了写在气泡下面（`DeliveryStatusLabel`）；正在看的会话没有"有新回复"
        let shown = PiShown(session)
        HStack(spacing: 4) {
            PiStateDot(shown: shown, size: Self.dot)
            Text(shown.label).fontWeight(shown.needsYou ? .medium : nil).foregroundStyle(shown.labelTint(palette))
                .contentTransition(.opacity)
                .animation(Motion.quick, value: shown)
            if let undelivered {
                Dot().foregroundStyle(palette.failure)
                Text(undelivered).foregroundStyle(palette.failure)
            }
            if shown.clock != nil {
                Dot().foregroundStyle(palette.ink3)
                // 整个 App 只有这一个计时到秒：正看着的这个会话
                PiElapsed(shown: shown, font: Self.font, precision: .second)
            }
        }
        .font(Self.font)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private static let font = Typography.caption
    #if os(macOS)
    private static let dot: CGFloat = 8
    #else
    private static let dot: CGFloat = 6
    #endif
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
                Callout(tint: palette.attention, symbol: "questionmark.circle.fill", text: session.question?.displayText ?? session.detail ?? "", prominent: true, docked: true)
            }
        }
    }
}


/// 对话里的一格：一条（你的话、回答、系统行），或连着的几张预览收成的一组（同一处连着发的文件放在一张纸上）。
nonisolated enum ChatItem: Identifiable, Equatable {
    case entry(PiChatEntry)
    case previews([PiChatEntry])

    var id: UUID {
        switch self {
        case .entry(let entry): entry.id
        case .previews(let group): group[0].id
        }
    }

    static func of(_ entries: [PiChatEntry]) -> [ChatItem] {
        entries.reduce(into: []) { items, entry in
            guard entry.role == .preview else { return items.append(.entry(entry)) }
            if case .previews(let group) = items.last { items[items.count - 1] = .previews(group + [entry]) } else { items.append(.previews([entry])) }
        }
    }
}
