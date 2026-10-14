import CueStore
import SwiftUI


/// 会话页的对话（iOS 会话页、Mac 会话页共用）：你的话右侧墨色气泡，Pi 的回答左侧全宽 Markdown（不折叠），
/// 每轮回答上方一行这一轮的经过；你发出还没进对话的话接在末尾，气泡下写送达情况，失败的可重发；
/// Pi 在处理时末尾一行流光的进展（当前动作；计时在顶上一行），有子代理时下面逐个列出它们此刻的状态；出错时末尾写原因。滚动与输入框由平台放。
/// 减弱动态效果下也只有淡入淡出。
struct PiConversation: View {
    let session: PiSessionState
    /// 对话里的每一条（`ChatDerived` 按对话数据推好的）。
    let items: [PiChatEntry]
    /// 发出还没进对话的话要对着已有的消息认。
    let messages: [PiChatMessage]
    var deliveries: [DeliveryRequest] = []
    /// 至少排开最近这么多条（不用懒加载栈，见 `ChatScroll`）；更早的由 `showEarlier` 再排开一段。
    let window: Int
    var showEarlier: () -> Void = {}
    @Environment(\.chatHighlight) private var highlight
    @Environment(AppServices.self) private var services
    @State private var opened: PreviewOpening?
    /// 每段排出来的尺寸（实测）、正在屏上的段、整列的宽：离屏远的段换成同样高的空白（`segment(_:of:)`）。
    @State private var sizes: [Int: CGSize] = [:]
    @State private var onScreen: Set<Int> = []
    @State private var width: CGFloat = 0

    var body: some View {
        let all = items
        let notes = services.settings.replyNotes(for: session.id)
        let first = Self.firstSegment(count: all.count, window: window)
        VStack(alignment: .leading, spacing: Self.spacing) {
            if first > 0 {
                EarlierRow(hidden: first * Self.segment, action: showEarlier)
            }
            if all.isEmpty { RecapPreview(session: session) }
            // 一段一段排，每段只按内容比较：上面再排开一段、下面来了新消息时，没变的段不重算也不重排，
            // 系统直接用上次量好的尺寸（整列一起排时，每排开一段都把已排开的全部重量一遍，长对话里一次几百毫秒）
            let last = Self.segments(all.count) - 1
            ForEach(first..<(last + 1), id: \.self) { index in
                segment(index, of: all, last: last, notes: notes)
                    .onScrollVisibilityChange(threshold: 0.01) { visible in
                        if visible { onScreen.insert(index) } else { onScreen.remove(index) }
                    }
            }
            ForEach(PiChat.outgoing(deliveries, messages: messages)) { request in OutgoingBubble(request: request, session: session) }
            ending
        }
        // 刻度滑条按 id 跳到你的某句话（`ChatFollow.jump`）：滚动区只认滚动目标布局里的行
        .scrollTargetLayout()
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width.rounded() } action: { width = $0 }
        #if os(iOS)
        // 手机上长按出的是消息菜单，挑字走菜单里的"选择文本"：对话里的字不开行内选择，每行少建一套文字交互。
        // 挂在弹出预览之内：从这里打开的文件预览照常可选
        .environment(\.inlineTextSelection, false)
        #endif
        .previewPresenter($opened)
        .task(id: items.count) {
            guard let title = DebugHooks.preset.openPreview else { return }
            opened = items.lazy.flatMap { entry in entry.previews.map { PreviewOpening(preview: $0, batch: entry.previews) } }
                .first { $0.preview.title == title }
        }
    }

    /// 一段：在屏上或离屏上不到 `spare` 段的、最新一段（还会长）、描圈的那条所在的段（刻度滑条正要跳过去）、还没量过的段排真的；
    /// 其余换成量好的那么高的空白。挂着的视图数就不随翻过的深度变多（整列都挂着时，翻到 300 轮前排开一段要 200ms 以上），
    /// 内容高也不变：换的时候正在读的不动，滚动区不用补偿。
    /// 宽度变了（拖窗口、转屏），量过的高按宽度反比估（字一行排得越宽越矮），排成真的时再换成实测：
    /// 不估就得把翻过的段全排一遍，翻到 200 轮前拖一下窗口边主线程要卡 1 秒以上。
    @ViewBuilder private func segment(_ index: Int, of all: [PiChatEntry], last: Int, notes: [ReplyNote]) -> some View {
        let items = Array(all[(index * Self.segment)..<min((index + 1) * Self.segment, all.count)])
        if let size = sizes[index], width > 0, index != last, !onScreen.contains { abs($0 - index) <= Self.spare },
            !items.contains(where: { $0.id == highlight })
        {
            Color.clear.frame(height: (size.height * size.width / width).rounded())
        } else {
            ChatSegment(items: items, session: session, highlight: highlight, notes: notes, opened: $opened)
                .equatable()
                .onGeometryChange(for: CGSize.self) { CGSize(width: $0.size.width.rounded(), height: $0.size.height) } action: {
                    sizes[index] = $0
                }
        }
    }

    /// 屏上那几段上下各再排几段真的：快甩时滑进来的先是排好的，不露空白。
    static let spare = 1

    static var spacing: CGFloat { 16 }
    /// 最初至少排开几条；一段几条（每次再排开一段）。段按从最早那条起的位置切，排开更早的只是在上面多显示一段，已有的段不变。
    static let firstWindow = 4, segment = 5

    static func segments(_ count: Int) -> Int { (count + segment - 1) / segment }

    /// 排开最近 `window` 条要从第几段起。
    static func firstSegment(count: Int, window: Int) -> Int { max(0, count - window) / segment }

    /// 对话末尾：处理中的进展（带子代理）、出错的原因。
    @ViewBuilder private var ending: some View {
        if session.state.isWorking || !session.subagents.isEmpty { LiveStatus(session: session) }
        if session.state == .known(.error) {
            Callout(.failure, text: session.detail ?? "Mac 没有说明原因")
        }
    }
}


/// 对话里的一段（`PiConversation.segment` 条）。只按内容比较：同样的几条、描圈的那条与批注（只看本段里的）、同一个会话就不重算。
private struct ChatSegment: View, Equatable {
    let items: [PiChatEntry]
    let session: PiSessionState
    let highlight: UUID?
    let notes: [ReplyNote]
    @Binding var opened: PreviewOpening?
    @Environment(\.palette) private var palette

    init(items: [PiChatEntry], session: PiSessionState, highlight: UUID?, notes: [ReplyNote], opened: Binding<PreviewOpening?>) {
        self.items = items
        self.session = session
        self.highlight = highlight.flatMap { id in items.contains { $0.id == id } ? id : nil }
        self.notes = notes.filter { note in items.contains { $0.id == note.entry } }
        _opened = opened
    }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.items == rhs.items && lhs.highlight == rhs.highlight && lhs.notes == rhs.notes
            && lhs.session.id == rhs.session.id && lhs.session.projectID == rhs.session.projectID
    }

    private static var turnGap: CGFloat { 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: PiConversation.spacing) {
            ForEach(items) { item in row(item) }
        }
    }

    @ViewBuilder private func row(_ entry: PiChatEntry) -> some View {
        switch entry.role {
        case .user:
            UserBubble(stored: entry.text, highlighted: entry.id == highlight, fromCue: entry.fromCue) {
                MessageActions(text: entry.text, kind: .mine, session: session)
            }
                // 你的话开始新的一轮：轮与轮之间比轮内（你的话与它的回答）松一截
                .padding(.top, Self.turnGap)
        case .pi:
            ReplyBlock(text: entry.text, meta: entry.meta, tools: entry.tools, session: session, notes: notes.filter { $0.entry == entry.id })
        case .system:
            // 会话文件里的系统记录（压缩）：居中一行小字，不是谁说的话
            Text(entry.text).font(Typography.meta).foregroundStyle(palette.ink3).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.vertical, 4)
        case .preview:
            PreviewGroup(previews: entry.previews) { opened = PreviewOpening(preview: $0, batch: entry.previews) }
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
    static func window(reaching id: UUID, in items: [PiChatEntry]) -> Int? {
        items.firstIndex { $0.id == id }.map { items.count - $0 }
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


/// 会话顶栏（Mac 工具栏标题、手机顶栏）里名字旁的状态，只在在跑或要你注意时出现：在跑（工作中、话在路上）是状态标、状态词与到秒的计时；
/// 等你确认、出错、没能送达、需要 /reload、已结束只有状态标与状态词（带色）。Mac 不画状态标，只有着色的字：标题玻璃里唯一的圆是任务的完成圈；有没送到的话时接一句胭脂的"N 句没送到"（`PiChat.undeliveredNote`）。
/// 不是 Pi 的会话最前面写是哪家 Agent（`AgentMark`），歇着时也写。
/// 歇着（该你了、新会话、有新回复）的 Pi 会话什么都不写，顶栏只有名字。所在与"后台"不放在这里（顶栏一行只说一件事），写在"⋯"菜单的最上面（`PiPlace.menuTitle`）。
struct PiSessionSubtitle: View {
    let session: PiSessionState
    var undelivered: String?
    /// 由 Cue 跟进（`SessionDigest.cueFollows`）：等回答时写"等 Cue 回答"。
    var cueFollows = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        // 顶栏只说会话自己的状态：你的话到哪了写在气泡下面（`DeliveryStatusLabel`）；正在看的会话没有"有新回复"
        let shown = PiShown(session, cue: cueFollows ? workspace.cue.name : nil)
        let speaks = shown.isLive || shown.needsYou || [.restart, .ended, .cueAsking].contains(shown.status)
        let mark = session.agentMark
        if speaks || undelivered != nil || mark != nil {
            HStack(spacing: 4) {
                if mark != nil {
                    AgentMark(session: session, font: Self.font)
                    if speaks || undelivered != nil { Dot().foregroundStyle(palette.ink3) }
                }
                if speaks { PiShownLabel(shown: shown) }
                if let undelivered {
                    if speaks { Dot().foregroundStyle(palette.failure) }
                    Text(undelivered).foregroundStyle(palette.failure)
                }
                if shown.isLive, shown.clock != nil {
                    Dot().foregroundStyle(palette.ink3)
                    // 整个 App 只有这一个计时到秒：正看着的这个会话
                    PiElapsed(shown: shown, font: Self.font, style: .header)
                }
            }
            .font(Self.font)
            .fixedSize()
            .accessibilityElement(children: .combine)
        }
    }

    private static let font = Typography.caption
}


/// 顶栏里的状态（会话页与 Cue 页同一个样子）：着色的状态词，手机上前面加状态标（Mac 的标题玻璃里不画圆）。
struct PiShownLabel: View {
    let shown: PiShown
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            #if os(iOS)
            PiStateDot(shown: shown, size: 6)
            #endif
            Text(shown.label).fontWeight(shown.needsYou ? .medium : nil).foregroundStyle(shown.labelTint(palette))
                .contentTransition(.opacity)
                .animation(Motion.quick, value: shown)
        }
    }
}


/// 等你确认时固定在输入框上方的问题：能从这里答的是问题卡（选项一点即答，答完随问题清空而消失），
/// 只能在 Agent 那边答的（问题本身答不了，或这个会话做不到，`PiSessionState.answerableQuestion`）写明原文与去处。
struct PiQuestionDock: View {
    let session: PiSessionState
    var deliveries: [DeliveryRequest] = []

    var body: some View {
        if session.state == .known(.waitingForUser) {
            if let question = session.answerableQuestion {
                QuestionCard(session: session, question: question, deliveries: deliveries).id(question.promptID)
            } else {
                // 去哪答写在回复框的位置上（各平台不同），这里只放问题
                Callout(.question, text: session.question?.displayText ?? session.detail ?? "", docked: true)
            }
        }
    }
}
