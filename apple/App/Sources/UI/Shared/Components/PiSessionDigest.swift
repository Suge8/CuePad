import CueStore
import CueText
import SwiftUI

/// 一个 Pi 会话页一次读取的数据：会话记录、它所在的项目、对话（从早到晚）、发给它的请求（先发的在前）。
/// 会话记录没了（Mac 上的会话文件被删）时 `session` 为 nil；`sessionID` 由调用方带上，发给它的请求照样读得到。
nonisolated struct SessionDigest: Sendable, Equatable {
    var session: PiSessionState?
    var project: Project?
    var deliveries: [DeliveryRequest]
    var messages: [PiChatMessage] = []

    /// 会话页要观察的表。
    static let tables: Set<StoreTable> = [.piSessionStates, .piMessages, .deliveryRequests, .projects]

    static func read(_ id: UUID, sessionID: String?, from store: isolated CueStore) throws -> SessionDigest {
        let session = try store.piSessionPage(PiSessionQuery(id: id)).items.first?.state
        let ref = session?.sessionID ?? sessionID
        return SessionDigest(
            session: session,
            project: try session?.projectID.flatMap { try store.project($0) },
            deliveries: try store.deliveryRequests()
                .filter { $0.target.kind == .known(.piSession) && $0.target.ref == ref }
                .sorted { $0.createdAt < $1.createdAt },
            messages: try ref.map { try store.piMessages(of: $0) } ?? [])
    }
}

/// 有色调的提示块：等你确认（注意色，正文放大）、出错（失败色）。
struct Callout: View {
    let tint: Color
    let title: String
    let text: String
    let prominent: Bool
    /// 正文下的一句说明（如"要在 Mac 上回答"）。
    var note: String?
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(tint)
            if !text.isEmpty {
                Text(text).font(prominent ? .title3.weight(.medium) : .body).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let note { Text(note).font(.footnote).foregroundStyle(palette.ink3) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(palette.dark ? 0.16 : 0.1), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(tint.opacity(palette.highContrast ? 0.8 : 0.3)))
        .accessibilityElement(children: .combine)
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
    private var failed: Bool { sent?.status == .known(.failed) }
    /// 点下即算在答（请求写成前也是），按钮立刻停用，不重复作答。
    private var answering: Bool { tapped != nil && writeError == nil && !failed }
    private var failure: String? { writeError ?? (failed ? sent?.resultDetail ?? "没能送达" : nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("等你确认").font(.footnote.weight(.semibold)).foregroundStyle(palette.attention)
            if !question.text.isEmpty {
                // 这一页最醒目的东西
                Text(question.text).font(.title3.weight(.medium)).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // 送不到 Mac 时不让答：写进去的请求会一直停在送达中
            controls.disabled(answering || !services.reachesPiHost)
            if !services.reachesPiHost {
                Text("\(SyncSummary(services.syncStatus).title)，现在答不了；同步恢复后再答，或在 Mac 上回答")
                    .font(.footnote).foregroundStyle(palette.ink3)
            } else if answering, sent?.status == .known(.succeeded) {
                Text("已答，等 Mac 上的 Pi 继续").font(.footnote).foregroundStyle(palette.ink3)
            } else if let failure {
                Text(failure).font(.footnote).foregroundStyle(palette.failure)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.attention.opacity(palette.dark ? 0.16 : 0.1), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.attention.opacity(palette.highContrast ? 0.8 : 0.3)))
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
        case .text:
            // 文字型问题在回复框里答（`MacDelivery.reply`），这里不再放第二个输入框
            Label("在下面的回复框里回答", systemImage: "arrow.down").font(.subheadline).foregroundStyle(palette.ink2)
        case nil:
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

/// 问题卡上的回答按钮：纸面描边或墨色实底，触摸目标 44pt；按下只变淡，不缩放（减弱动态效果下也一样）。
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
            .background(prominent ? palette.accent : palette.paper, in: shape)
            .overlay { if !prominent { shape.strokeBorder(palette.hair) } }
            .contentShape(shape)
            // 停用（送不到 Mac、已经答了）时变淡，看得出点不了
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// 请求的送达情况：送达中（等 Mac 接手与正在发送都算）、已送达（往返多久）、没能送达。
struct DeliveryStatusLabel: View {
    let request: DeliveryRequest
    /// 目标会话已结束：在途时写"正在唤醒…"。
    var waking = false
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch request.status {
            case .known(.pending), .known(.executing):
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(waking ? "正在唤醒…" : "送达中") }.foregroundStyle(palette.ink2)
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

/// 会话计时，读法与写法见 `PiClock`："已运行 4 分"、"已等 30 秒"、"1 时 2 分前"。
struct PiElapsed: View {
    let clock: PiClock
    var font: Font = .footnote
    @Environment(\.palette) private var palette

    init(session: PiSessionState, font: Font = .footnote) {
        self.init(state: session.state, stateSince: session.stateSince, busySince: session.busySince, font: font)
    }

    init(state: Open<PiWorkState>, stateSince: Date, busySince: Date?, font: Font = .footnote) {
        clock = PiClock.reading(state, stateSince: stateSince, busySince: busySince)
        self.font = font
    }

    var body: some View {
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
private struct PiClockSchedule: TimelineSchedule {
    let clock: PiClock

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> some Sequence<Date> {
        sequence(first: startDate) { clock.nextChange(after: $0) }
    }
}

