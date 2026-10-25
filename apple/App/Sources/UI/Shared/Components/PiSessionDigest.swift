import CueStore
import enum CueStore.Table  // 盖过 SwiftUI.Table
import SwiftUI

/// 一个 Pi 会话页一次读取的数据：会话记录、它所在的项目、对话（从早到晚）、发给它的请求（先发的在前）、可换的模型与命令。
/// 会话记录没了（Mac 上的会话文件被删）时 `session` 为 nil；`sessionID` 由调用方带上，发给它的请求照样读得到。
nonisolated struct SessionDigest: Sendable, Equatable {
    var session: PiSessionState?
    var project: Project?
    var deliveries: [DeliveryRequest]
    var messages: [PiChatMessage] = []
    /// 这个会话里 Agent 发到手机上看的文件（对话里按 `.preview` 消息的位置显示，见 `PiChat.entries`）。
    var previews: [PiPreview] = []
    /// 对话里 Cue 说的那几条的请求 id（按发送记录认，`cueSentDeliveries`）；还在路上的看请求自己的来源。
    var cueSent: Set<UUID> = []
    /// 可换的模型与能用的斜杠命令（会话记录指向的目录记录；会话结束后也在，从没报过的会话没有）。
    var catalog: AgentCatalog?

    /// 正在请 Mac 补写对话（很久以前的会话没有对话时）：请求还在路上（`Speech`，超时就不再说正在补写）。
    func fetchingTranscript(at moment: Speech.Moment) -> Bool {
        deliveries.contains { $0.mode == .known(.transcript) && Speech.trip($0, at: moment).inTransit }
    }

    /// 顶栏写的会话名：改名在路上时是新名（`PiRename`，与会话行读同一条：发给它的最近一条改名）。
    func title(at moment: Speech.Moment) -> String? {
        session.map { PiRename.title(of: $0, request: DeliveryRequest.latestRename(in: deliveries), at: moment) }
    }

    /// 此刻没能送达的话有几句（`Speech.undelivered`，会话行同一个数）。
    func undelivered(at moment: Speech.Moment) -> Int { Speech.undelivered(deliveries, at: moment) }

    /// 模型与思考强度此刻显示什么：最近一次换的还在路上时显示要换成的值，没换成时显示会话当前的值并带原因（到哪了按 `Speech`）。
    /// 思考强度按显示的模型夹取（`PiThinkingLevel.clamped`），换了模型不会短暂显示新模型没有的档位。
    func config(at moment: Speech.Moment) -> PiConfigShown {
        let current = PiConfigShown(model: session?.model, thinking: session?.thinking?.known, context: session?.context, pending: false, failure: nil)
        // 只看换模型、思考强度的请求：改名同走配置请求，但与这两样无关
        guard let request = deliveries.last(where: { $0.config.map { $0.model != nil || $0.thinking != nil } == true }),
              let wanted = request.config else { return current }
        switch Speech.trip(request, at: moment) {
        case .sending, .sent:
            let model = wanted.model.flatMap { key in catalog?.models.first { $0.key == key } } ?? current.model
            let thinking = (wanted.thinking ?? current.thinking).map { $0.clamped(to: model?.thinkingLevels ?? []) }
            return PiConfigShown(model: model, thinking: thinking, context: current.context, pending: true, failure: nil)
        case .delivered: return current
        case .failed(let failure):
            return PiConfigShown(model: current.model, thinking: current.thinking, context: current.context, pending: false, failure: failure)
        }
    }

    static func read(_ id: UUID, sessionID: String?, from store: isolated CueStore) throws -> SessionDigest {
        let session = try store.piSessionPage(PiSessionQuery(id: id)).items.first?.state
        let ref = session?.sessionID ?? sessionID
        let messages = try ref.map { try store.piMessages(of: $0) } ?? []
        return SessionDigest(
            session: session,
            project: try session?.projectID.flatMap { try store.project($0) },
            deliveries: try ref.map { try store.deliveryRequests(toSession: $0) } ?? [],
            messages: messages,
            previews: try ref.map { try store.previews(of: $0) } ?? [],
            cueSent: try messages.isEmpty ? [] : store.cueSentDeliveries(among: messages.compactMap(\.deliveryID)),
            catalog: try session?.catalogID.flatMap { try store.agentCatalog($0) })
    }
}

/// 会话页回复框上方模型与思考强度的显示值（`SessionDigest.config`）。
nonisolated struct PiConfigShown: Equatable {
    var model: PiModelOption?
    var thinking: PiThinkingLevel?
    /// 上下文余量（会话记录上的，用量条显示；没有模型时为 nil）。
    var context: PiContextUsage?
    var pending: Bool
    /// 最近一次没换成的原因（`Speech`：Mac 报的，或一直没发出、超时）。
    var failure: Speech.Failure?
}

/// 提示块（等你确认的问题、出错、没能结束）：彩色只在行首的状态图形上（`PiStateGlyph`，与状态标同一个样子：问题是赭黄问号圆、出错是胭脂圆叹号），正文中性；
/// 问题的正文放大（问题是这一页最醒目的东西）。下面可接作答控件。
/// 层级只有两层：对话里的（出错的原因）是纸，属于内容；贴在回复框上方、要你处理的（`docked`：问题卡、没能结束）是玻璃，
/// 与回复框同属底部玻璃那一层。顶上只有系统玻璃（标题、圆钮），不在对话上另浮卡片。
struct Callout<Accessory: View>: View {
    /// 问题是 `.asking`，出错与没能结束是 `.failed`。
    let status: PiShown.Status
    let text: String
    var docked = false
    @ViewBuilder var accessory: Accessory
    @Environment(\.palette) private var palette

    init(_ status: PiShown.Status, text: String, docked: Bool = false, @ViewBuilder accessory: () -> Accessory) {
        self.status = status
        self.text = text
        self.docked = docked
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                PiStateGlyph(status: status)
                Text(Widow.joined(text)).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(status == .asking ? Typography.title : Typography.body)
            accessory
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CalloutSurface(docked: docked))
        .accessibilityElement(children: Accessory.self == EmptyView.self ? .combine : .contain)
    }
}

extension Callout where Accessory == EmptyView {
    init(_ status: PiShown.Status, text: String, docked: Bool = false) {
        self.init(status, text: text, docked: docked) { EmptyView() }
    }
}

/// 提示块的面：对话里是纸，贴在回复框上方是玻璃（与回复框同一层、同样的圆角）。
private struct CalloutSurface: ViewModifier {
    let docked: Bool

    func body(content: Content) -> some View {
        if docked { content.glass(in: .rect(cornerRadius: PiReplyBar.radius, style: .continuous)) } else { content.paper(radius: 16) }
    }
}

/// 等你确认、能从这里答的问题：问句与怎么答（`WaitAnswer`，同 Cue 页拍板卡：确认框"否 / 是"，选择框每个选项一颗胶囊，
/// Mac 上按 1–9 直接作答；文字型的在下面的回复框里答）。答出去后停用，等 Mac 那边弹窗收起、问题清空（卡片随之消失）；没送达就地写原因，可以再答。
struct QuestionCard: View {
    let session: PiSessionState
    let question: PiQuestion
    let deliveries: [DeliveryRequest]

    var body: some View {
        Callout(.asking, text: question.text, docked: true) {
            WaitAnswer(wait: .session(session, task: nil), replyElsewhere: true, deliveries: deliveries)
        }
    }
}

/// 会话计时，读法与写法见 `PiClock`，读哪一种由 `PiShown.clock` 定："运行了 4 分钟"、"刚刚"（等你确认的第一分钟）、"2 小时前"。
/// 列表里到分钟；会话页顶栏传 `.header`；会话行只写时长（`.span`）。
struct PiElapsed: View {
    let shown: PiShown
    var font: Font = Typography.meta
    var style = PiClock.Style.list
    @Environment(\.palette) private var palette

    var body: some View {
        if let clock = shown.clock {
            LiveText(style: clock.live(style))
                .font(font.monospacedDigit())
                // 状态标与状态词已带色，计时保持中性，一行里只有一处彩色
                .foregroundStyle(palette.ink3)
        }
    }
}

