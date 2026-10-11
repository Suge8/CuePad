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
    /// 只排最近这么多条（Mac）；更早的点最上面一行再排开 `Self.step` 条。nil 是全排（iOS 靠懒加载）。
    var window: Binding<Int>?
    @Environment(\.palette) private var palette
    @Environment(\.chatInverted) private var inverted
    @Environment(\.chatAtNewest) private var atNewest
    @Environment(\.chatInsets) private var insets
    @Environment(\.chatHighlight) private var highlight
    @State private var opened: PiPreview?

    var body: some View {
        // iOS 懒加载：只排看得见的几条（整段排开时，长对话的每条回答都在推入那一刻排版、栅格化，转场的前一百多毫秒画不出来），
        // 在倒置的滚动区里按新到旧给出，懒加载从最新那条起排。
        // Mac 不用懒加载（见 `ChatStack`）：只排最近几条（`window`），位置才是确定的
        let all = ChatItem.of(PiChat.entries(messages, previews: previews))
        let entries = window.map { Array(all.suffix($0.wrappedValue)) } ?? all
        let outgoing = PiChat.outgoing(deliveries, messages: messages)
        ChatStack(alignment: .leading, spacing: Self.spacing) {
            if inverted {
                // 让出底下回复框与键盘占的高（`ChatScroll`）；它和第一条之间本有一份行距，扣掉
                Color.clear.frame(height: max(0, insets.bottom - Self.spacing)).accessibilityHidden(true)
                // 读屏仍按先后读：越早的越先
                ending.chatRow().accessibilitySortPriority(-Double(entries.count + outgoing.count))
                ForEach(Array(outgoing.enumerated()).reversed(), id: \.element.id) { index, request in
                    OutgoingBubble(request: request, session: session).chatRow().accessibilitySortPriority(-Double(entries.count + index))
                }
                ForEach(Array(entries.enumerated()).reversed(), id: \.element.id) { index, item in
                    row(item).chatRow().accessibilitySortPriority(-Double(index))
                }
                if entries.isEmpty { RecapPreview(session: session).chatRow() }
                // 最早那头让出顶上的栏（同上）
                Color.clear.frame(height: max(0, insets.top - Self.spacing)).accessibilityHidden(true)
            } else {
                if let window, entries.count < all.count {
                    EarlierRow(hidden: all.count - entries.count, fillsViewport: atNewest, window: window)
                }
                if entries.isEmpty { RecapPreview(session: session) }
                ForEach(entries) { item in row(item) }
                ForEach(outgoing) { request in OutgoingBubble(request: request, session: session) }
                ending
            }
        }
        // 刻度滑条按 id 跳到你的某句话（`ChatFollow.jump`）：滚动区只认滚动目标布局里的行
        .scrollTargetLayout()
        .frame(maxWidth: .infinity, alignment: .leading)
        .previewPresenter($opened)
        .task(id: previews.map(\.id)) {
            if let title = DebugHooks.preset.openPreview { opened = previews.first { $0.title == title } }
        }
    }

    private static var spacing: CGFloat { 16 }
    /// 窗口里最初排几条、每次多排几条。
    static let firstWindow = 4, step = 10
    private static var turnGap: CGFloat { 14 }

    @ViewBuilder private func row(_ item: ChatItem) -> some View {
        switch item {
        case .previews(let group): PreviewGroup(previews: group.compactMap(\.preview)) { opened = $0 }
        case .entry(let entry): row(entry)
        }
    }

    @ViewBuilder private func row(_ entry: PiChatEntry) -> some View {
        switch entry.role {
        case .user:
            UserBubble(text: Dotted(entry.text), highlighted: entry.id == highlight)
                .chatContextMenu { MessageMenu(text: entry.text, kind: .mine, session: session) } preview: { BubbleText(text: Dotted(entry.text)).padding(4) }
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

    /// 对话末尾：处理中的进展（带子代理）、出错的原因。
    @ViewBuilder private var ending: some View {
        if session.state.isWorking || !session.subagents.isEmpty { LiveStatus(session: session) }
        if session.state == .known(.error) {
            Callout(tint: palette.failure, symbol: "exclamationmark.circle.fill", text: session.detail ?? "Mac 没有说明原因")
        }
    }
}


#if os(macOS)
/// Mac 的对话整段排开最近几条、不用懒加载栈：懒加载栈靠估计高度定位，数据晚到或内容变化后再滚到最新，可见区里的行有时排不出来
/// （页面空白，滚一下才出现）；整段排开位置是确定的。代价是排开的每条都要当场排版，所以只排最近几条。
typealias ChatStack = VStack
#else
private typealias ChatStack = LazyVStack
#endif


/// 排开的最上面一行：还有更早的对话，点一下再排开一段。贴着最新时它进了可见区，说明排开的几条铺不满一屏，自动再排开。
struct EarlierRow: View {
    let hidden: Int
    let fillsViewport: Bool
    @Binding var window: Int
    @Environment(\.palette) private var palette
    @State private var visible = false

    var body: some View {
        Button("更早的 \(min(hidden, PiConversation.step)) 条") { window += PiConversation.step }
            .font(Typography.caption.weight(.semibold)).foregroundStyle(palette.ink3)
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, minHeight: 28)
            .onScrollVisibilityChange { visible = $0 }
            .task(id: [visible ? 1 : 0, window]) { if visible, fillsViewport { window += PiConversation.step } }
    }
}


extension PiConversation {
    /// Mac 只排最近几条（`window`）：要跳到 `id` 那一条（刻度滑条）时至少要排开几条。
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
enum ChatItem: Identifiable {
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
