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
    @Environment(\.chatBottomSpace) private var bottomSpace
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
                Color.clear.frame(height: max(0, bottomSpace - Self.spacing)).accessibilityHidden(true)
                // 读屏仍按先后读：越早的越先
                ending.chatRow().accessibilitySortPriority(-Double(entries.count + outgoing.count))
                ForEach(Array(outgoing.enumerated()).reversed(), id: \.element.id) { index, request in
                    OutgoingBubble(request: request, session: session).chatRow().accessibilitySortPriority(-Double(entries.count + index))
                }
                ForEach(Array(entries.enumerated()).reversed(), id: \.element.id) { index, item in
                    row(item).chatRow().accessibilitySortPriority(-Double(index))
                }
                if entries.isEmpty { RecapPreview(session: session).chatRow() }
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .previewPresenter($opened)
        #if DEBUG
        .task(id: previews.map(\.id)) {
            // 截图验收：-CuePadOpenPreview <标题> 直接打开那张预览
            if let title = DebugScene.defaults.string(forKey: "CuePadOpenPreview") { opened = previews.first { $0.title == title } }
        }
        #endif
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
            UserBubble(text: entry.text, highlighted: entry.id == highlight)
                .chatContextMenu { MessageMenu(text: entry.text, kind: .mine, session: session) } preview: { BubbleText(text: entry.text).padding(4) }
                // 你的话开始新的一轮：轮与轮之间比轮内（你的话与它的回答）松一截
                .padding(.top, Self.turnGap)
        case .pi:
            ReplyBlock(text: entry.text, meta: entry.meta, session: session)
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
private typealias ChatStack = VStack
#else
private typealias ChatStack = LazyVStack
#endif

/// 排开的最上面一行：还有更早的对话，点一下再排开一段。贴着最新时它进了可见区，说明排开的几条铺不满一屏，自动再排开。
private struct EarlierRow: View {
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
            if let undelivered { Text("· \(undelivered)").foregroundStyle(palette.failure) }
            if shown.clock != nil {
                Text("·").foregroundStyle(palette.ink3)
                PiElapsed(shown: shown, font: Self.font)
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

private extension AnyTransition {
    /// 对话里一条出现或消失：只淡入淡出，动画随过渡自带。不给整段对话挂动画：倒置的滚动区里新的一条加在逻辑顶端，
    /// 其余各行的位移若也跟着动画，正在读的那段会先被推走再滑回来
    static let entry = AnyTransition.opacity.animation(Motion.quick)
}

/// 你的一句话：右侧气泡，最宽到所在一栏的四分之三；还在路上的整颗变淡。
private struct UserBubble: View {
    private static let widthFraction: CGFloat = 0.78

    /// 长的话折到这么多行，点"展开"看全：会话页的重点是回答，你自己写的长提示词不该是整屏最重的一块。
    private static let foldedLines = 6

    let text: String
    var trip = BubbleTrip.arrived
    var highlighted = false
    @Environment(\.palette) private var palette
    @State private var expanded = false
    /// 折起时文字确实被截掉了（按同一宽度量全文的高度比较）。
    @State private var truncated = false

    var body: some View {
        TrailingFraction(fraction: Self.widthFraction) {
            BubbleText(
                text: text, highlighted: highlighted, trip: trip, lineLimit: expanded ? nil : Self.foldedLines, truncated: $truncated,
                expand: truncated && !expanded ? { expanded = true } : nil)
        }
        .transition(.entry)
    }
}

/// 气泡本身（颜色是 `Palette.bubble`），长按的预览也是它。Mac 上可以直接拖选文字。
private struct BubbleText: View {
    let text: String
    var highlighted = false
    var trip = BubbleTrip.arrived
    var lineLimit: Int?
    /// 给了时报告文字是否被 `lineLimit` 截掉。
    var truncated: Binding<Bool>?
    /// 折起着时：最后一行末尾渐隐，接着是"展开"（在气泡里，就在被截断的地方）。
    var expand: (() -> Void)?
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HStack(alignment: .center, spacing: 8) {
            if trip == .failed {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(palette.failure).accessibilityLabel("没能送达")
            }
            Text(text)
                .font(Typography.reading).foregroundStyle(palette.ink)
                .lineLimit(lineLimit)
                .selectableOnHover()
                .background(alignment: .topLeading) { if let truncated, lineLimit != nil { fullHeight(truncated) } }
                .overlay(alignment: .bottomTrailing) { if let expand { expandButton(expand) } }
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(palette.bubble, in: shape)
                .overlay { edge(shape) }
                // 在路上：半透明加虚线边，浅色深色一样看得出还没到
                .opacity(trip == .inTransit ? 0.6 : 1)
        }
        .animation(Motion.quick, value: highlighted)
        .animation(Motion.quick, value: trip)
    }

    private func expandButton(_ expand: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [palette.bubble.opacity(0), palette.bubble], startPoint: .leading, endPoint: .trailing).frame(width: 36)
            Button("展开", action: expand)
                .font(Typography.reading.weight(.semibold)).foregroundStyle(palette.ink2)
                .buttonStyle(.plain)
                .padding(.leading, 4)
                .background(palette.bubble)
        }
        .fixedSize()
    }

    /// 同一宽度下排全文要多高，与折起后的高度比，量出有没有被截掉；只读几何、不影响自己的排版（藏起的全文不占位）。
    private func fullHeight(_ truncated: Binding<Bool>) -> some View {
        GeometryReader { shown in
            Text(text).font(Typography.reading).fixedSize(horizontal: false, vertical: true)
                .frame(width: shown.size.width, alignment: .leading)
                .hidden()
                .onGeometryChange(for: Bool.self) { $0.size.height > shown.size.height + 1 } action: { truncated.wrappedValue = $0 }
        }
    }

    @ViewBuilder private func edge(_ shape: RoundedRectangle) -> some View {
        switch trip {
        case .inTransit: shape.strokeBorder(palette.ink2, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .failed: shape.strokeBorder(palette.failure, lineWidth: 1)
        case .arrived: shape.strokeBorder(highlighted ? palette.signature : palette.bubbleEdge, lineWidth: highlighted ? 2 : 1)
        }
    }
}

/// 你的话到哪了：进了对话、还在路上、没能送达。
private enum BubbleTrip { case arrived, inTransit, failed }

/// 一条消息的长按菜单（Mac 右键）只在这里定义。Pi 的回答：复制、选择文本（手机上打开可自由选择的全文；Mac 直接拖选）、
/// 分享、存为灵感；你的话：复制、编辑后重发（放回输入框，接在已写的字后面）、存为灵感。存为灵感进会话所属的项目。
private struct MessageMenu: View {
    enum Kind { case reply, mine }

    let text: String
    let kind: Kind
    let session: PiSessionState
    var selectText: (() -> Void)?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("复制", systemImage: "doc.on.doc") {
            Clipboard.copy(text)
            workspace.say("已复制")
        }
        switch kind {
        case .reply:
            if let selectText { Button("选择文本", systemImage: "selection.pin.in.out", action: selectText) }
            ShareLink(item: text) { Label("分享", systemImage: "square.and.arrow.up") }
        case .mine:
            Button("编辑后重发", systemImage: "square.and.pencil", action: editAgain)
        }
        Button("存为灵感", systemImage: "square.and.arrow.down") {
            let text = text, session = session
            workspace.attempt { try await workspace.saveReply(text, of: session) }
        }
    }

    /// 放回这个会话的回复框（草稿只有一份，见 `AppSettings.replyDraft`）：已经写了字就接在后面，不覆盖。
    private func editAgain() {
        let settings = workspace.services.settings
        var draft = settings.replyDraft(for: session.id)
        draft.text = [draft.text, text].filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n")
        settings.setReplyDraft(draft, for: session.id)
    }
}

/// 对话还没同步过来时（很久前的会话、刚连上的会话）先放记录上的最近一轮：你说的话与 Agent 的回答；
/// 还没说过话的会话写一句怎么开始。对话到了就被它替换。
private struct RecapPreview: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let prompt = session.pendingPrompt ?? session.lastPrompt {
                Text("最近一轮 · 完整对话还在同步").font(Typography.caption).foregroundStyle(palette.ink3)
                UserBubble(text: prompt)
                if session.pendingPrompt == nil, let reply = session.lastReply { MarkdownText(source: reply) }
            } else if !session.hasStarted, session.state != .known(.ended) {
                Text("还没说过话，在下面说第一句").font(Typography.secondary).foregroundStyle(palette.ink3)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Pi 的一轮回答：上方一行弱化的经过，下面全宽 Markdown，长也直接全显；长按（Mac 右键）是消息菜单（`MessageMenu`）。
private struct ReplyBlock: View {
    let text: String
    let meta: String?
    let session: PiSessionState
    @Environment(\.palette) private var palette
    @State private var selecting = false

    /// 长按预览的大小：长回答只露开头，不撑满屏。
    private static let previewWidth: CGFloat = 360
    private static let previewHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let meta {
                // 与代码块、表格同一套底色与圆角（`ChatBlock`），收成贴着字的一小块
                Label(meta, systemImage: "wrench.and.screwdriver")
                    .labelStyle(MetaLabel())
                    .font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink2)
                    .padding(.horizontal, ChatBlock.inset / 1.5).padding(.vertical, 4)
                    .background(palette.fill, in: ChatBlock.shape)
            }
            MarkdownText(source: text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .chatContextMenu {
            #if os(iOS)
            MessageMenu(text: text, kind: .reply, session: session) { selecting = true }
            #else
            MessageMenu(text: text, kind: .reply, session: session)
            #endif
        } preview: {
            MarkdownText(source: text).padding(16)
                .frame(width: Self.previewWidth, alignment: .leading)
                .frame(maxHeight: Self.previewHeight, alignment: .top)
                .clipped()
                .background(palette.paper)
        }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: text) }
        #endif
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
            UserBubble(text: text, trip: failed ? .failed : request.isOpen ? .inTransit : .arrived)
            HStack(spacing: 10) {
                if failed {
                    if let reason = request.failure { Text(reason).font(Typography.caption).foregroundStyle(palette.failure).lineLimit(2) }
                    // 送不到 Mac 时也露出来（停用），看得出能重发
                    Button("重发", systemImage: "arrow.clockwise", action: retry)
                        .font(Typography.caption.weight(.semibold)).foregroundStyle(palette.failure)
                        .padding(.horizontal, 10).frame(minHeight: 28)
                        .overlay(Capsule().strokeBorder(palette.failure, lineWidth: 1))
                        .frame(minHeight: 44).contentShape(.rect)
                        .buttonStyle(.plain)
                        .disabled(!workspace.services.reachesPiHost)
                } else {
                    DeliveryStatusLabel(request: request, session: session).font(Typography.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .chatContextMenu {
            if failed { Button("重发", systemImage: "arrow.clockwise", action: retry).disabled(!workspace.services.reachesPiHost) }
            Button("移除", systemImage: "xmark", role: .destructive, action: remove)
        } preview: {
            BubbleText(text: text).padding(4)
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
/// 有子代理时下面是它们的汇总（`PiSubagentList`）。回答到了它就被回答替换。
private struct LiveStatus: View {
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

/// 对话里的一格：一条（你的话、回答、系统行），或连着的几张预览收成的一组（同一处连着发的文件放在一张纸上）。
private enum ChatItem: Identifiable {
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

/// 一轮回答上方的经过：小图标贴着字，比系统的 Label 间距紧，读作一行注脚。
private struct MetaLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small).accessibilityHidden(true)
            configuration.title
        }
    }
}

private extension View {
    /// 进行中的文字：底色是淡墨，一道墨色的光从左往右反复扫过（`LoopLayer`）；减弱动态效果时是静止的次要色。
    func shimmering() -> some View { modifier(Shimmer()) }
}

private struct Shimmer: ViewModifier {
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
