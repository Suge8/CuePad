import CueStore
import enum CueStore.Table
import SwiftUI

nonisolated struct SessionDigest: Sendable, Equatable {
    var session: SessionState?
    var project: Project?
    var deliveries: [DeliveryRequest]
    var messages: [ChatMessage] = []
    var previews: [PreviewItem] = []
    var cueSent: Set<UUID> = []
    var catalog: AgentCatalog?
    var defaultModel: ModelOption?
    var task: SessionTask?
    var tier: CueTier?

    func fetchingTranscript(at moment: Speech.Moment) -> Bool {
        deliveries.contains { $0.mode == .known(.transcript) && Speech.trip($0, at: moment).inTransit }
    }

    func title(at moment: Speech.Moment) -> String? {
        session.map { SessionRename.title(of: $0, request: DeliveryRequest.latestRename(in: deliveries), at: moment) }
    }

    var delivery: DeliveryRequest? { deliveries.last { $0.mode.known.map(DeliveryMode.toSession.contains) == true } }

    func undelivered(at moment: Speech.Moment) -> Int { Speech.undelivered(deliveries, at: moment) }

    func config(at moment: Speech.Moment) -> ConfigShown {
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
            task: item?.task,
            tier: try session.flatMap { session in try store.cueProfile()?.activeHost == nil ? nil : CueTier.of(session, chosen: store.chosenTiers()) })
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

struct QuestionCard: View {
    let session: SessionState
    let question: Question

    var body: some View {
        Callout(.asking, text: question.text, docked: true) {
            WaitAnswer(session: session)
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
                .foregroundStyle(palette.ink3)
        }
    }
}

