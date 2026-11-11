import CueStore
import enum CueStore.Table  // 盖过 SwiftUI.Table
import SwiftUI

/// 会话记录没了（Mac 上的会话文件被删）时 `session` 为 nil；`sessionID` 由调用方带上，发给它的请求照样读得到。
nonisolated struct SessionDigest: Sendable, Equatable {
    var session: SessionState?
    var project: Project?
    var deliveries: [DeliveryRequest]
    var messages: [ChatMessage] = []
    var previews: [PreviewItem] = []
    var cueSent: Set<UUID> = []
    var catalog: AgentCatalog?
    var task: SessionTask?

    func fetchingTranscript(at moment: Speech.Moment) -> Bool {
        deliveries.contains { $0.mode == .known(.transcript) && Speech.trip($0, at: moment).inTransit }
    }

    func title(at moment: Speech.Moment) -> String? {
        session.map { SessionRename.title(of: $0, request: DeliveryRequest.latestRename(in: deliveries), at: moment) }
    }

    var delivery: DeliveryRequest? { deliveries.last { $0.mode.known.map(DeliveryMode.toSession.contains) == true } }

    func undelivered(at moment: Speech.Moment) -> Int { Speech.undelivered(deliveries, at: moment) }

    /// 模型与思考强度此刻显示什么：最近一次换的还在路上时显示要换成的值，没换成时显示会话当前的值，是你换的、之后还没对它做别的才带上那一句（到哪了按 `Speech`）。
    /// 思考强度按显示的模型夹取（`ThinkingLevel.clamped`），换了模型不会短暂显示新模型没有的档位。
    func config(at moment: Speech.Moment) -> ConfigShown {
        let current = ConfigShown(model: session?.model, thinking: session?.thinking?.known, fast: session?.fast, context: session?.context, pending: false, failure: nil)
        // 只看换模型、思考强度的请求：改名同走配置请求，但与这两样无关
        guard let request = deliveries.last(where: { $0.config.map { $0.model != nil || $0.thinking != nil || $0.fast != nil } == true }),
              let wanted = request.config else { return current }
        switch Speech.trip(request, at: moment) {
        case .preparing, .sending, .sent:
            let model = wanted.model.flatMap { key in catalog?.models.first { $0.key == key } } ?? current.model
            let thinking = (wanted.thinking ?? current.thinking).map { $0.clamped(to: model?.thinkingLevels ?? []) }
            return ConfigShown(model: model, thinking: thinking, fast: wanted.fast ?? current.fast, context: current.context, pending: true, failure: nil)
        case .delivered: return current
        case .unconfirmed: return current
        case .failed(let failure):
            // 没换成只说给换的那个人、说到他对这个会话的下一个动作为止：Cue 换的由它看工具结果自己处理；之后又说了话、改了名，这句就过时了
            guard !request.isFromCue, request.id == deliveries.last?.id else { return current }
            let name = wanted.model.map { key in catalog?.models.first { $0.key == key }?.name ?? key.id } ?? wanted.thinking.map { String(localized: "思考 \($0.label)") }
            let text = name.map { String(localized: "没换成 \($0)：\(failure.text)") } ?? String(localized: "没换成：\(failure.text)")
            return ConfigShown(model: current.model, thinking: current.thinking, fast: current.fast, context: current.context, pending: false, failure: text)
        }
    }

    static func read(_ id: UUID, sessionID: String?, from store: isolated CueStore) throws -> SessionDigest {
        let item = try store.piSessionPage(SessionQuery(id: id)).items.first
        let session = item?.state
        let ref = session?.sessionID ?? sessionID
        let messages = try ref.map { try store.piMessages(of: $0) } ?? []
        return SessionDigest(
            session: session,
            project: try session?.projectID.flatMap { try store.project($0) },
            deliveries: try ref.map { try store.deliveryRequests(toSession: $0) } ?? [],
            messages: messages,
            previews: try ref.map { try store.previews(of: $0) } ?? [],
            cueSent: try messages.isEmpty ? [] : store.cueSentDeliveries(among: messages.compactMap(\.deliveryID)),
            catalog: try session?.catalogID.flatMap { try store.agentCatalog($0) },
            task: item?.task)
    }
}

nonisolated struct ConfigShown: Equatable {
    var model: ModelOption?
    var thinking: ThinkingLevel?
    var fast: Bool? = nil
    var context: ContextUsage?
    var pending: Bool
    var failure: String?
}

/// 彩色只在行首的状态图形上，正文中性；对话里的（出错的原因）是平放的纸，属于内容；贴在回复框上方、要你处理的（`docked`：问题卡、出错、没能结束）是浮起的纸，与 Cue 页的拍板卡同一个面（`dockedPaper`），进出同它从回复框后面升起、沉回（`DockedCard`）。
struct Callout<Accessory: View>: View {
    let status: SessionShown.Status
    let text: String
    var docked = false
    @ViewBuilder var accessory: Accessory
    @Environment(\.palette) private var palette

    init(_ status: SessionShown.Status, text: String, docked: Bool = false, @ViewBuilder accessory: () -> Accessory) {
        self.status = status
        self.text = text
        self.docked = docked
        self.accessory = accessory()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
                StateGlyph(status: status)
                Text(Widow.joined(text)).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(status == .asking ? Typography.title : Typography.body)
            accessory
        }
        .padding(Spacing.block)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(CalloutSurface(docked: docked))
        .accessibilityElement(children: Accessory.self == EmptyView.self ? .combine : .contain)
    }
}

extension Callout where Accessory == EmptyView {
    init(_ status: SessionShown.Status, text: String, docked: Bool = false) {
        self.init(status, text: text, docked: docked) { EmptyView() }
    }
}

private struct CalloutSurface: ViewModifier {
    let docked: Bool

    func body(content: Content) -> some View {
        if docked {
            content.dockedPaper().containerShape(.rect(cornerRadius: Radius.field))
        } else {
            content.paper().containerShape(.rect(cornerRadius: Radius.card))
        }
    }
}

/// 答出去后停用，等 Mac 那边弹窗收起、问题清空（卡片随之消失）；没送达就地写原因，可以再答。
struct QuestionCard: View {
    let session: SessionState
    let question: Question

    var body: some View {
        Callout(.asking, text: question.text, docked: true) {
            WaitAnswer(wait: .session(session, task: nil), replyElsewhere: true)
        }
    }
}

struct SessionElapsed: View {
    let shown: SessionShown
    var font: Font = Typography.meta
    var style = SessionClock.Style.list
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

