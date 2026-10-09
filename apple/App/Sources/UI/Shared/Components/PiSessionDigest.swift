import CueStore
import SwiftUI

/// 一个 Pi 会话页一次读取的数据：会话记录、它所在的项目、对话（从早到晚）、发给它的请求（先发的在前）。
/// 会话记录没了（Mac 上的会话文件被删）时 `session` 为 nil；`sessionID` 由调用方带上，发给它的请求照样读得到。
nonisolated struct SessionDigest: Sendable, Equatable {
    var session: PiSessionState?
    var project: Project?
    var deliveries: [DeliveryRequest]
    var messages: [PiChatMessage] = []

    /// 顶栏写的会话名：改名在路上时是新名（`PiRename`，与会话行读同一条：发给它的最近一条改名）。
    var title: String? {
        session.map { PiRename.title(of: $0, request: DeliveryRequest.latestRename(in: deliveries)) }
    }

    /// 模型与思考强度此刻显示什么：最近一次换的还在路上时显示要换成的值，没换成时显示会话当前的值并带原因。
    /// 思考强度按显示的模型夹取（`PiThinkingLevel.clamped`），换了模型不会短暂显示新模型没有的档位。
    var config: PiConfigShown {
        let current = PiConfigShown(model: session?.model, thinking: session?.thinking?.known, context: session?.context, pending: false, failure: nil)
        // 只看换模型、思考强度的请求：改名同走配置请求，但与这两样无关
        guard let request = deliveries.last(where: { $0.config.map { $0.model != nil || $0.thinking != nil } == true }),
              let wanted = request.config else { return current }
        if request.isOpen {
            let model = wanted.model.flatMap { key in session?.models.first { $0.key == key } } ?? current.model
            let thinking = (wanted.thinking ?? current.thinking).map { $0.clamped(to: model?.thinkingLevels ?? []) }
            return PiConfigShown(model: model, thinking: thinking, context: current.context, pending: true, failure: nil)
        }
        guard let failure = request.failure else { return current }
        return PiConfigShown(model: current.model, thinking: current.thinking, context: current.context, pending: false, failure: failure)
    }

    /// 会话页要观察的表。
    static let tables: Set<StoreTable> = [.piSessionStates, .piMessages, .deliveryRequests, .projects]

    static func read(_ id: UUID, sessionID: String?, from store: isolated CueStore) throws -> SessionDigest {
        let session = try store.piSessionPage(PiSessionQuery(id: id)).items.first?.state
        let ref = session?.sessionID ?? sessionID
        return SessionDigest(
            session: session,
            project: try session?.projectID.flatMap { try store.project($0) },
            deliveries: try ref.map { try store.deliveryRequests(toSession: $0) } ?? [],
            messages: try ref.map { try store.piMessages(of: $0) } ?? [])
    }
}

extension PiThinkingLevel {
    /// 夹到 `supported` 里（与 Pi 的 clampThinkingLevel 同规则）：支持就是它，否则先往高找最近的一档，没有再往低找；
    /// 不知道支持哪些时原样。
    nonisolated func clamped(to supported: [PiThinkingLevel]) -> PiThinkingLevel {
        guard !supported.isEmpty, !supported.contains(self) else { return self }
        let all = Self.allCases
        let index = all.firstIndex(of: self) ?? 0
        return all[index...].first(where: supported.contains) ?? all[..<index].last(where: supported.contains) ?? supported[0]
    }
}

/// 会话页回复框上方模型与思考强度的显示值（`SessionDigest.config`）。
nonisolated struct PiConfigShown: Equatable {
    var model: PiModelOption?
    var thinking: PiThinkingLevel?
    /// 上下文余量（会话记录上的，圆环显示；没有模型时为 nil）。
    var context: PiContextUsage?
    /// 换的请求还在路上。
    var pending: Bool
    /// 最近一次没换成的原因。
    var failure: String?
}

/// 会话页顶上固定的一句（不随对话滚走）：旧版扩展的会话怎么接上。
struct PiRestartNotice: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette

    var body: some View {
        if session.state == .known(.incompatible) {
            Callout(
                tint: palette.attention, symbol: "arrow.clockwise.circle.fill",
                text: "这个会话还在用升级前的旧版扩展，CuePad 看不到它的进展、也发不进去。在终端里对这个会话执行 /reload 就能接上。")
        }
    }
}

/// 对话里的提示块（等你确认的问题、出错）：一张纸，彩色只在行首的状态符号上（等你确认赭黄问号、出错胭脂叹号），
/// 正文中性；`prominent` 时正文放大（问题是这一页最醒目的东西）。下面可接作答控件。
struct Callout<Accessory: View>: View {
    let tint: Color
    let symbol: String
    let text: String
    var prominent = false
    @ViewBuilder var accessory: Accessory
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                Text(text).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .font(prominent ? .title3.weight(.medium) : .body)
            accessory
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 16)
        .accessibilityElement(children: Accessory.self == EmptyView.self ? .combine : .contain)
    }
}

extension Callout where Accessory == EmptyView {
    init(tint: Color, symbol: String, text: String, prominent: Bool = false) {
        self.init(tint: tint, symbol: symbol, text: text, prominent: prominent) { EmptyView() }
    }
}

/// 等你确认、能从这里答的问题：确认框是"是 / 否"，选择框每个选项一个按钮，输入框填了发送。
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

    @Environment(AppServices.self) private var services

    private var sent: DeliveryRequest? { requestID.flatMap { id in deliveries.first { $0.id == id } } }
    private var failed: Bool { sent?.failure != nil }
    /// 点下即算在答（请求写成前也是），按钮立刻停用，不重复作答。
    private var answering: Bool { tapped != nil && writeError == nil && !failed }
    private var failure: String? { writeError ?? sent?.failure }

    var body: some View {
        Callout(tint: palette.attention, symbol: "questionmark.circle.fill", text: question.text, prominent: true) {
            // 送不到 Mac 时不让答：写进去的请求会一直停在送达中
            controls.disabled(answering || !services.reachesPiHost)
            if !services.reachesPiHost {
                Text("\(SyncSummary(services.syncStatus).title)，现在答不了；同步恢复后再答，或在 Mac 上回答")
                    .font(.footnote).foregroundStyle(palette.ink3)
            } else if answering, sent?.status == .known(.succeeded) {
                Text("已答，等 Mac 上的 Agent 继续").font(.footnote).foregroundStyle(palette.ink3)
            } else if let failure {
                Text(failure).font(.footnote).foregroundStyle(palette.failure)
            }
        }
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
                ForEach(question.options, id: \.self) { option in choice(.option(option), prominent: false, leading: true) }
            }
        case .text, nil:
            // 文字型问题在回复框里答（`MacDelivery.reply`），回复框的占位写着
            EmptyView()
        }
    }

    /// 一个回答按钮：点了的那个转为"送达中"，别的变淡。
    private func choice(_ value: PiAnswerValue, prominent: Bool, leading: Bool = false) -> some View {
        let busy = answering && tapped == value
        return Button { answer(value) } label: {
            HStack(spacing: 8) {
                if busy {
                    ProgressView().controlSize(.small)
                    Text("送达中")
                } else {
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

/// 问题卡上的回答按钮：淡底加细边，或墨色实底（确认的"是"），触摸目标 44pt；按下缩一点、松开回弹（`Motion.pressDown/pressUp`）。
/// 不用签名色：确认的常是部署、覆盖这类收不回的事，品牌色不该推着人点"是"。
private struct AnswerButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.palette) private var palette
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(prominent ? palette.onAccent : palette.ink)
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(prominent ? palette.accent : palette.fill, in: shape)
            .overlay { if !prominent { shape.strokeBorder(palette.ink3.opacity(0.5), lineWidth: 1) } }
            .contentShape(shape)
            .scaleEffect(configuration.isPressed ? Press.control : 1)
            // 停用（送不到 Mac、已经答了）时变淡，看得出点不了
            .opacity(enabled ? 1 : 0.45)
            .animation(configuration.isPressed ? Motion.pressDown : Motion.pressUp, value: configuration.isPressed)
    }
}

/// 请求的送达情况，说法同会话行（`PiDelivery.transit`）：发送中、排队中、送达中、正在唤醒、已送达（往返多久）、没能送达。
struct DeliveryStatusLabel: View {
    let request: DeliveryRequest
    /// 发给哪个会话；开新会话的请求没有。
    var session: PiSessionState?
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch request.status {
            case .known(.pending), .known(.executing):
                // 发给已结束的会话：Mac 先在后台把它唤醒再送达
                let busy = session.map { $0.isWorking || $0.state == .known(.waitingForUser) } ?? false
                let text = session?.state == .known(.ended) ? "正在唤醒" : PiDelivery.transit(request, busy: busy)
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(text) }.foregroundStyle(palette.ink2)
            case .known(.succeeded):
                Label(request.roundTrip.map { "已送达 · \(PiClock.duration(Double($0.components.seconds)))" } ?? "已送达", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(palette.ink2)
            case .known(.failed): Label("没能送达", systemImage: "exclamationmark.triangle.fill").foregroundStyle(palette.failure)
            case .unknown: Label("未知状态", systemImage: "questionmark.circle").foregroundStyle(palette.ink2)
            }
        }
        .font(.footnote.weight(.medium))
        .id(request.status)
        .transition(.opacity)
        .animation(Motion.quick, value: request.status)
    }
}

/// 会话计时，读法与写法见 `PiClock`，读哪一种由 `PiShown.clock` 定："已运行 4 分"、"已等 30 秒"、"已发出 3 秒"、"1 小时 2 分前"。
struct PiElapsed: View {
    let shown: PiShown
    var font: Font = .footnote
    @Environment(\.palette) private var palette

    var body: some View {
        if let clock = shown.clock { label(clock) }
    }

    private func label(_ clock: PiClock) -> some View {
        // 只在文字会变的时刻重画；不在屏幕上的行不画，也就不刷新
        TimelineView(PiClockSchedule(clock: clock)) { context in
            Text(clock.text(now: context.date))
                .font(font.monospacedDigit())
                // 状态标与状态词已带色，计时保持中性，一行里只有一处彩色
                .foregroundStyle(palette.ink3)
        }
    }
}

/// `PiClock` 的文字在哪些时刻会变（见 `nextChange`）。
struct PiClockSchedule: TimelineSchedule {
    let clock: PiClock

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        sequence(first: startDate) { clock.nextChange(after: $0) }
    }
}

