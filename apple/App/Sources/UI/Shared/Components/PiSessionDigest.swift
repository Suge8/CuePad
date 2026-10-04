import CueStore
import CueText
import SwiftUI

/// 一个 Pi 会话的近况一次读取的数据：会话记录、它所在的项目、发给它的请求（先发的在前）。
/// 会话记录没了（结束 7 天后删除）时 `session` 为 nil；`sessionID` 由调用方带上，发给它的请求照样读得到。
nonisolated struct SessionDigest: Sendable, Equatable {
    var session: PiSessionState?
    var project: Project?
    var deliveries: [DeliveryRequest]

    static func read(_ id: UUID, sessionID: String?, from store: isolated CueStore) throws -> SessionDigest {
        let session = try store.piSessionStates().first { $0.id == id }
        let ref = session?.sessionID ?? sessionID
        return SessionDigest(
            session: session,
            project: try session?.projectID.flatMap { try store.project($0) },
            deliveries: try store.deliveryRequests()
                .filter { $0.target.kind == .known(.piSession) && $0.target.ref == ref }
                .sorted { $0.createdAt < $1.createdAt })
    }
}

/// 会话近况（iOS 的会话页、Mac 侧栏的会话详情共用）：状态块（名字、状态、在哪、进度；等你确认的问题最醒目，
/// 出错写原因），然后是最近一轮——你说的一行（弱化）与 Pi 答的全文（较长时折起）。已结束的整页更淡但可读。
/// 发过去的请求（`DeliveryStack`）与回复框由各平台放在它下面。
struct PiSessionDigest: View {
    let session: PiSessionState
    let project: Project?
    /// 发给这个会话的请求：问题卡据此显示作答的送达情况。
    var deliveries: [DeliveryRequest] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            StatusBlock(session: session, project: project, deliveries: deliveries)
            RecentRound(session: session)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(session.state == .known(.ended) ? 0.75 : 1)
    }
}

/// 状态块：状态是第一视觉变量（状态标 + 带色的状态词），名字与时长其次，在哪与进度再次。
private struct StatusBlock: View {
    let session: PiSessionState
    let project: Project?
    let deliveries: [DeliveryRequest]
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title).font(.title2.weight(.bold)).foregroundStyle(palette.ink).lineLimit(2)
                    Spacer(minLength: 8)
                    PiElapsed(session: session)
                }
                HStack(spacing: 6) {
                    PiStateDot(state: session.state, size: 8)
                    Text(session.state.label).font(.subheadline.weight(.semibold)).foregroundStyle(session.state.tint(palette))
                    if let place = PiPlace.name(of: session, project: project) {
                        Text("· \(place)").font(.subheadline).foregroundStyle(palette.ink3).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                if session.state.isWorking, let action = PiProgress.line(of: session) {
                    Text(action).font(session.detailIsCode ? .subheadline.monospaced() : .subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                }
            }
            switch session.state.known {
            case .waitingForUser:
                if let question = session.question, question.isAnswerable {
                    QuestionCard(session: session, question: question, deliveries: deliveries).id(question.promptID)
                } else {
                    // 只能在 Pi 里答的问题：原文照抄（含换行与选项），是此刻最需要看的东西
                    Callout(
                        tint: palette.attention, title: "等你确认", text: session.question?.displayText ?? session.detail ?? "",
                        prominent: true, note: "这个问题要在 Mac 上回答")
                }
            case .error:
                Callout(tint: palette.failure, title: "出错", text: session.detail ?? "Mac 没有说明原因", prominent: false)
            default:
                EmptyView()
            }
        }
    }
}

/// 有色调的提示块：等你确认（注意色，正文放大）、出错（失败色）。
private struct Callout: View {
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
private struct QuestionCard: View {
    let session: PiSessionState
    let question: PiQuestion
    let deliveries: [DeliveryRequest]
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var requestID: UUID?
    /// 点了的那个回答：它的按钮显示送达中。
    @State private var tapped: PiAnswerValue?
    @State private var writeError: String?
    @State private var text = ""

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
            HStack(spacing: 8) {
                TextField("回答", text: $text)
                    .onSubmit(submitText)
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(palette.paper, in: .rect(cornerRadius: 12, style: .continuous))
                Button(action: submitText) {
                    if tapped != nil && answering { ProgressView().controlSize(.small) } else { Text("发送") }
                }
                .buttonStyle(AnswerButtonStyle(prominent: true))
                .fixedSize()
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
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

    private func submitText() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        answer(.text(text))
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

/// 最近一轮：上面一行弱化的"你说"（点开看全句），下面 Pi 答的全文；回答较长时先折起，可展开。
private struct RecentRound: View {
    let session: PiSessionState
    @Environment(\.palette) private var palette
    @State private var replyExpanded = false
    @State private var promptExpanded = false

    /// 收起时回答显示的行数；超过这么多行（或字数）才给"展开"。
    private static let collapsedLines = 8
    private static let collapsedCharacters = 320
    private static let collapsedHeight: CGFloat = 200

    var body: some View {
        if session.lastPrompt == nil && session.lastReply == nil {
            Text("还没有近况。Pi 回答之后，这里会显示它最后答的。")
                .font(.subheadline).foregroundStyle(palette.ink3)
                .padding(.horizontal, 4)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                if let prompt = session.lastPrompt {
                    Button { withAnimation(Motion.quick) { promptExpanded.toggle() } } label: {
                        Text("你说：\(prompt)").font(.footnote).foregroundStyle(palette.ink3)
                            .lineLimit(promptExpanded ? nil : 1)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(promptExpanded ? "收起" : "展开全句")
                }
                if let reply = session.lastReply {
                    let long = reply.count > Self.collapsedCharacters
                        || reply.split(separator: "\n", omittingEmptySubsequences: false).count > Self.collapsedLines
                    VStack(alignment: .leading, spacing: 6) {
                        // 折起时截到约八行高，底部淡出，看得出下面还有
                        MarkdownText(source: reply)
                            .frame(maxHeight: long && !replyExpanded ? Self.collapsedHeight : nil, alignment: .top)
                            .clipped()
                            .mask {
                                if long && !replyExpanded {
                                    LinearGradient(stops: [.init(color: .black, location: 0.75), .init(color: .clear, location: 1)],
                                                   startPoint: .top, endPoint: .bottom)
                                } else {
                                    Color.black
                                }
                            }
                        if long {
                            Button(replyExpanded ? "收起" : "展开全文") { withAnimation(Motion.quick) { replyExpanded.toggle() } }
                                .font(.subheadline.weight(.medium))
                                .frame(minHeight: 44)
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 16)
        }
    }
}

/// 发过去的请求，贴在回复框上方：默认只有最新一条，更早的折成"更早 N 条"，点开在它上方列出。
struct DeliveryStack: View {
    let deliveries: [DeliveryRequest]
    /// 还能发给它的会话；nil 时不给重发。
    let session: PiSessionState?
    @Environment(\.palette) private var palette
    @State private var showsEarlier = false

    private static let earlierMaxHeight: CGFloat = 220

    var body: some View {
        if let latest = deliveries.last {
            let earlier = deliveries.dropLast()
            VStack(alignment: .leading, spacing: 0) {
                if !earlier.isEmpty {
                    Button(showsEarlier ? "收起更早的" : "更早 \(earlier.count) 条") { withAnimation(Motion.quick) { showsEarlier.toggle() } }
                        .buttonStyle(.plain)
                        .font(.footnote.weight(.medium)).foregroundStyle(palette.ink3)
                        .padding(.horizontal, 16).frame(minHeight: 36)
                    if showsEarlier {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(earlier) { request in
                                    DeliveryRow(request: request, session: session)
                                    Divider().padding(.leading, 16)
                                }
                            }
                        }
                        .frame(maxHeight: Self.earlierMaxHeight)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                    }
                }
                DeliveryRow(request: latest, session: session)
            }
            .paper(radius: 16)
            .animation(Motion.quick, value: deliveries.map(\.id))
        }
    }
}

/// 发给会话的一条请求（会话页里贴在回复框上方的那几条，送达情况只在这里写）：内容、方式、送达中 / 已送达多久 / 没能送达与原因。
/// 失败时可以重发（会话还在时）或移除。
struct DeliveryRow: View {
    let request: DeliveryRequest
    /// 还能发给它的会话；nil 时不给重发。
    let session: PiSessionState?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.body).foregroundStyle(palette.ink).lineLimit(2)
                Spacer(minLength: 8)
                DeliveryStatusLabel(request: request)
            }
            Text("\(DateLabel.short(request.createdAt)) · \(request.mode.label)")
                .font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
            if request.status == .known(.failed) {
                if let reason = request.resultDetail { Text(reason).font(.footnote).foregroundStyle(palette.failure) }
                HStack(spacing: 10) {
                    if retryable { Button("重发", systemImage: "arrow.clockwise", action: retry) }
                    Button("移除", systemImage: "xmark", role: .destructive, action: remove)
                }
                .font(.subheadline.weight(.medium))
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .transition(.opacity)
        .contextMenu {
            if retryable { Button("再发一次", systemImage: "paperplane", action: retry) }
            Button("移除", systemImage: "xmark", role: .destructive, action: remove)
        }
    }

    /// 作答显示答了什么；作答不重发（弹窗多半已经换了，要答就在问题卡上再答）。送不到 Mac 时也不给重发。
    private var title: String {
        if let answer = request.answer { return "答：\(answer.value.label)" }
        let title = CardText(request.content).title
        return title.isEmpty ? "图片" : title
    }

    private var retryable: Bool { session != nil && request.answer == nil && workspace.services.reachesPiHost }

    /// 同样的内容与方式再发一次；新请求写成后移除这条失败的。
    private func retry() {
        guard let session else { return }
        let old = request
        workspace.attempt {
            _ = try await workspace.services.requestMacDelivery(
                old.content, to: session, mode: old.mode.known ?? .followUp, card: old.cardID, task: old.taskID)
            try await workspace.services.store.deleteDelivery(old.id)
        }
    }

    private func remove() {
        let id = request.id
        workspace.perform { try await $0.deleteDelivery(id) }
    }
}

/// 请求的送达情况：送达中（等 Mac 接手与正在发送都算）、已送达（往返多久）、没能送达。
struct DeliveryStatusLabel: View {
    let request: DeliveryRequest
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch request.status {
            case .known(.pending), .known(.executing):
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("送达中") }.foregroundStyle(palette.ink2)
            case .known(.succeeded):
                Label(request.roundTrip.map { "已送达 · \(Self.text($0))" } ?? "已送达", systemImage: "checkmark.circle.fill")
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

    /// 往返时间："3 秒"、"2 分"。
    static func text(_ duration: Duration) -> String {
        let seconds = Int(duration.components.seconds)
        return seconds < 60 ? "\(max(seconds, 1)) 秒" : "\(seconds / 60) 分"
    }
}

/// 会话计时，读法见 `PiClock`："已运行 0:42"、"已等 1:07"、"5 分钟前"。
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
        switch clock {
        case .waiting(let since):
            Text("已等 \(Text(since, style: .timer))").font(font.monospacedDigit()).foregroundStyle(palette.attention)
        case .running(let since):
            Text("已运行 \(Text(since, style: .timer))").font(font.monospacedDigit()).foregroundStyle(palette.ink3)
        case .ago(let date):
            Text(date, format: .relative(presentation: .named)).font(font).foregroundStyle(palette.ink3)
        }
    }
}
