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
        deliveries.contains { $0.mode == .known(.transcript) && Speech.trip($0, at: moment) == .sending }
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
        case .sending:
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
    /// 最近一次没换成的原因（`Speech`：Mac 报的，或超时、本机同步不通）。
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

/// 等你确认、能从这里答的问题：确认框是"是 / 否"，选择框每个选项一个按钮，输入框填了发送。
/// Mac 上选项带编号键帽，按 1–9 直接作答（卡片出现时拿到键盘焦点，回复框此时收成"先在上面作答"、不占键盘）。
/// 答出去后按钮停用，等 Mac 那边弹窗收起、问题清空（卡片随之消失）；作答请求没能送达时就地写原因，可以再答。
struct QuestionCard: View {
    let session: PiSessionState
    let question: PiQuestion
    let deliveries: [DeliveryRequest]
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var requestID: UUID?
    /// 点了的那个回答：它的按钮显示送达中。
    @State private var tapped: PiAnswerValue?
    @State private var writeError: String?
    #if os(macOS)
    @FocusState private var keyboard: Bool
    #endif

    @Environment(AppServices.self) private var services

    /// 答的那条到哪了（`Speech`）；还没写成是 nil。
    private var sent: Speech.Trip? {
        requestID.flatMap { id in deliveries.first { $0.id == id } }.map { Speech.trip($0, at: services.speech) }
    }
    /// 点下即算在答（请求写成前也是），按钮立刻停用，不重复作答。
    private var answering: Bool { tapped != nil && writeError == nil && sent?.failure == nil }
    private var failure: String? { writeError ?? sent?.failure?.text(sync: services.syncStatus) }

    var body: some View {
        Callout(.asking, text: question.text, docked: true) {
            // 送不到 Mac 时不让答：写进去的请求会一直停在送达中
            controls.disabled(answering || !services.reachesPiHost)
            if !services.reachesPiHost {
                Text("\(SyncSummary(services.syncStatus).title)，现在答不了；同步恢复后再答，或在 Mac 上回答")
                    .font(Typography.meta).foregroundStyle(palette.ink3)
            } else if answering, sent == .delivered {
                Text("已答，等 Mac 上的 Agent 继续").font(Typography.meta).foregroundStyle(palette.ink3)
            } else if let failure {
                Text(failure).font(Typography.meta).foregroundStyle(palette.failure)
            }
        }
        #if os(macOS)
        .focusable(question.kind == .known(.select))
        .focusEffectDisabled()
        .focused($keyboard)
        .onAppear { keyboard = question.kind == .known(.select) }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard let number = Int(press.characters), question.options.indices.contains(number - 1),
                  !answering, services.reachesPiHost else { return .ignored }
            answer(.option(question.options[number - 1]))
            return .handled
        }
        #endif
    }

    @ViewBuilder private var controls: some View {
        switch question.kind.known {
        case .confirm:
            HStack(spacing: 10) {
                choice(.confirmed(false), prominent: false)
                choice(.confirmed(true), prominent: true)
            }
        case .select:
            VStack(spacing: 8) {
                ForEach(Array(question.options.enumerated()), id: \.element) { index, option in
                    choice(.option(option), prominent: false, leading: true, number: index < 9 ? index + 1 : nil)
                }
                if question.allowsOther {
                    Text("都不是？在下面的回复框里写你的回答").font(Typography.meta).foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        case .text, nil:
            // 文字型问题在回复框里答（`MacDelivery.reply`），回复框的占位写着
            EmptyView()
        }
    }

    /// 一个回答按钮：点了的那个转为"送达中"，别的变淡。
    /// `number`：Mac 上选项前的编号键帽（按这个数字键作答）。
    private func choice(_ value: PiAnswerValue, prominent: Bool, leading: Bool = false, number: Int? = nil) -> some View {
        let busy = answering && tapped == value
        return Button { answer(value) } label: {
            HStack(spacing: 8) {
                if busy {
                    Spinner(.small)
                    Text("送达中")
                } else {
                    #if os(macOS)
                    if let number { Keycap(text: "\(number)").accessibilityHidden(true) }
                    #endif
                    Text(value.label).multilineTextAlignment(leading ? .leading : .center)
                }
            }
            .frame(maxWidth: .infinity, alignment: leading && !busy ? .leading : .center)
        }
        .buttonStyle(AnswerButtonStyle(prominent: prominent))
        .accessibilityLabel(busy ? "\(value.label)，送达中" : value.label)
    }

    /// 写一条作答请求给会话所在的 Mac；写不进去时就地说明。
    private func answer(_ value: PiAnswerValue) {
        guard services.reachesPiHost else { return }
        writeError = nil
        requestID = nil
        withAnimation(Motion.quick) { tapped = value }
        Task {
            do {
                requestID = try await workspace.services.answer(value, to: session).id
            } catch {
                writeError = error.localizedDescription
            }
        }
    }
}

/// 问题卡上的回答按钮：淡底加细边，或墨色实底（确认的"是"），触摸目标 44pt；按下同 `PressStyle`（`PressFeedback`）。
/// 不用签名色：确认的常是部署、覆盖这类收不回的事，品牌色不该推着人点"是"。
/// 悬停同全 App 的按钮（`PressFeedback`）。
private struct AnswerButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View { AnswerButton(prominent: prominent, configuration: configuration) }
}

private struct AnswerButton: View {
    let prominent: Bool
    let configuration: ButtonStyleConfiguration
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .font(Typography.body.weight(.medium))
            .foregroundStyle(prominent ? palette.paper : palette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(prominent ? palette.ink : palette.fill, in: shape)
            .overlay { if !prominent { shape.strokeBorder(palette.hair, lineWidth: 1) } }
            .contentShape(shape)
            .modifier(PressFeedback(pressed: configuration.isPressed))
            // 停用（送不到 Mac、已经答了）时变淡，看得出点不了
            .opacity(enabled ? 1 : ControlMetrics.disabledOpacity)
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

