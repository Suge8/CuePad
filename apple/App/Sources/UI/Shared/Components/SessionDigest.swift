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
    /// 会话没记下模型时显示的（`CueStore.defaultModel(of:)`）。
    var defaultModel: ModelOption?
    var task: SessionTask?

    func fetchingTranscript(at moment: Speech.Moment) -> Bool {
        deliveries.contains { $0.mode == .known(.transcript) && Speech.trip($0, at: moment).inTransit }
    }

    func title(at moment: Speech.Moment) -> String? {
        session.map { SessionRename.title(of: $0, request: DeliveryRequest.latestRename(in: deliveries), at: moment) }
    }

    var delivery: DeliveryRequest? { deliveries.last { $0.mode.known.map(DeliveryMode.toSession.contains) == true } }

    func undelivered(at moment: Speech.Moment) -> Int { Speech.undelivered(deliveries, at: moment) }

    /// 模型、思考强度与加速此刻显示什么：每样各看最近一条动它的配置请求，还在路上就显示要换成的值，到头了（送达、未确认、没换成）显示会话当前的值（到哪了按 `Speech`）。
    /// 各看各的，不按最近那一条的终态一起定：一条只换强度的请求送达或失败，不把还在路上的换模型盖回旧值；更早、还在路上的那条也盖不过较新的已到头的同一样。
    /// 思考强度一律按显示的模型夹取（`ThinkingLevel.clamped`）：换了模型不显示新模型没有的档位，只换模型的请求送达后、Agent 报回新强度之前也一样。
    /// 没换成的那一句只说给换的那个人、说到他对这个会话的下一个动作为止：Cue 换的由它看工具结果自己处理；之后又说了话、改了名，这句就过时了。
    /// 模型按键对回清单里的那一项：会话文件索引写下的只有键（`CueStore.writeSessionHistory`），名字与档位在清单里。
    func config(at moment: Speech.Moment) -> ConfigShown {
        // 改名同走配置请求，但与这三样无关
        let requests = deliveries.filter { $0.config.map { $0.model != nil || $0.thinking != nil || $0.fast != nil } == true }
        func flying(_ carries: (SessionConfig) -> Bool) -> SessionConfig? {
            guard let request = requests.last(where: { $0.config.map(carries) == true }), Speech.trip(request, at: moment).awaitingResult else { return nil }
            return request.config
        }
        let listed = session?.model.map { model in catalog?.models.first { $0.key == model.key } ?? model }
        let model = flying { $0.model != nil }?.model.flatMap { key in catalog?.models.first { $0.key == key } } ?? listed ?? defaultModel
        let thinking = (flying { $0.thinking != nil }?.thinking ?? session?.thinking?.known).map { $0.clamped(to: model?.thinkingLevels ?? []) }
        let fast = flying { $0.fast != nil }?.fast ?? session?.fast
        let pending = requests.contains { Speech.trip($0, at: moment).awaitingResult }
        return ConfigShown(model: model, thinking: thinking, fast: fast, context: session?.context, pending: pending, failure: failure(of: requests.last, at: moment))
    }

    private func failure(of request: DeliveryRequest?, at moment: Speech.Moment) -> String? {
        guard let request, let wanted = request.config, case .failed(let failure) = Speech.trip(request, at: moment),
              !request.isFromCue, request.id == deliveries.last?.id else { return nil }
        let name = wanted.model.map { key in catalog?.models.first { $0.key == key }?.name ?? key.id } ?? wanted.thinking.map { String(localized: "思考 \($0.label)") }
        return name.map { String(localized: "没换成 \($0)：\(failure.text)") } ?? String(localized: "没换成：\(failure.text)")
    }

    static func read(_ id: UUID, sessionID: String?, from store: isolated CueStore) throws -> SessionDigest {
        let item = try store.sessionPage(SessionQuery(id: id)).items.first
        let session = item?.state
        let ref = session?.sessionID ?? sessionID
        let messages = try ref.map { try store.chatMessages(of: $0) } ?? []
        return SessionDigest(
            session: session,
            project: try session?.projectID.flatMap { try store.project($0) },
            deliveries: try ref.map { try store.deliveryRequests(toSession: $0) } ?? [],
            messages: messages,
            previews: try ref.map { try store.previews(of: $0) } ?? [],
            cueSent: try messages.isEmpty ? [] : store.cueSentDeliveries(among: messages.compactMap(\.deliveryID)),
            catalog: try session.flatMap { try store.catalog(of: $0) },
            defaultModel: try session.flatMap { try $0.model == nil ? store.defaultModel(of: $0) : nil },
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

