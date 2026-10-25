import CueStore
import SwiftUI

/// 一件拍板怎么答，答法只在这里：Cue 页拍板卡（`CueWaitDock`）与会话页的问题卡（`QuestionCard`）共用（进展页只看不答）。按问题的种类给：
/// - Cue 的提问：它的选项（`CueChoices`），"可以"是全件唯一的靛青；
/// - 会话的选择题：每个选项一颗胶囊，靠右、放不下换行（`ChipFlow`），长选项折行写全——选项不写进问句，也不给自由回答框（会话页上允许自己写的，提示在底下回复框里写）；
/// - 确认题："否 / 是"两颗普通胶囊：确认的常是部署、覆盖这类撤不回的事，不用主色推着人点"是"；
/// - 文字题：回答框（`BoardReply`，草稿同会话页）；会话页上回复框就在底下（`replyElsewhere`），这里不另给；
/// - 答不了的（编辑器这类只能在 Agent 里答的，`PiSessionState.answerableQuestion` 为空）：只有"打开会话"；会话页上不给（已经在里面了）。
/// 会话的答案写成一条作答请求给它所在的 Mac：点下即停用、那颗写"送达中"，送到了写"已答，等 Mac 上的 Agent 继续"，没送到就地写原因、可以再答；
/// 到哪了读库里答这道题（`promptID`）的那条请求，不记在视图里：切到别的卡再回来照样在，会话换了下一道题就是新的一题。
/// 同步到不了 Mac 时不让答、写明去哪答。Mac 的会话页上选择题按 1–9 直接作答（键帽在胶囊里）。
struct WaitAnswer: View {
    let wait: CueTally.Wait
    /// 回复框在页上别处（会话页）
    var replyElsewhere = false
    /// 发给这个会话的投送请求（会话页给全的）；不给时读在线会话收到的最近一条（`LiveSessions.deliveries`）
    var deliveries: [DeliveryRequest]?
    @Environment(Workspace.self) private var workspace
    /// Cue 的提问正在答（写成后它从等你里消失，写不成就恢复）
    @State private var ending = false

    var body: some View {
        switch wait {
        case .message(let message, _):
            CueChoices(message: message, disabled: ending) { choice in
                ending = true
                workspace.attempt {
                    defer { ending = false }
                    try await workspace.services.answerCueQuestion(message.id, choice)
                }
            }
        case .session(let session, _):
            SessionAnswer(session: session, replyElsewhere: replyElsewhere, deliveries: deliveries)
        }
    }
}

/// 会话在问的怎么答（`WaitAnswer`）：作答请求到哪了只在这里跟。
private struct SessionAnswer: View {
    let session: PiSessionState
    let replyElsewhere: Bool
    let deliveries: [DeliveryRequest]?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    /// 点了、请求还没出现在库里读到的那一下（写成前，或写不成的原因）。
    @State private var pending: Pending?
    #if os(macOS)
    @FocusState private var keyboard: Bool
    #endif

    private var question: PiQuestion? { session.answerableQuestion }

    private struct Pending {
        let promptID: String
        let value: PiAnswerValue
        var requestID: UUID?
        var error: String?
    }

    /// 答这道题最近的那条请求（先发的在前）。
    private var request: DeliveryRequest? {
        guard let promptID = question?.promptID else { return nil }
        let requests = deliveries ?? services.liveSessions.deliveries[session.sessionID].map { [$0] } ?? []
        return requests.last { $0.answer?.promptID == promptID }
    }

    /// 这道题刚点的、库里还读不到的那一下；读到了就以库里的为准。
    private var unseen: Pending? {
        guard let pending, pending.promptID == question?.promptID, pending.requestID == nil || pending.requestID != request?.id else { return nil }
        return pending
    }

    /// 点了的那个回答：它的胶囊显示送达中。
    private var tapped: PiAnswerValue? { unseen.map(\.value) ?? request?.answer?.value }
    private var writeError: String? { unseen?.error }
    private var sent: Speech.Trip? { unseen == nil ? request.map { Speech.trip($0, at: services.speech) } : nil }

    /// 点下即算在答（请求写成前也是），胶囊立刻停用，不重复作答。
    private var answering: Bool { tapped != nil && writeError == nil && sent?.failure == nil }
    private var failure: String? { writeError ?? sent?.failure?.text(sync: services.syncStatus) }

    var body: some View {
        switch question?.kind.known {
        case .confirm: answers([.confirmed(false), .confirmed(true)])
        case .select:
            answers((question?.options ?? []).map(PiAnswerValue.option), numbered: replyElsewhere,
                    other: replyElsewhere && question?.allowsOther == true)
        case .text: if !replyElsewhere { WaitReply(session: session) }
        case nil:
            if !replyElsewhere {
                chips {
                    Button("打开会话") { workspace.openSession(session.id, sessionID: session.sessionID) }
                        .buttonStyle(ControlButtonStyle(kind: .secondary))
                }
            }
        }
    }

    private func chips(@ViewBuilder _ content: () -> some View) -> some View {
        ChipFlow { content() }.frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// 几颗回答，下面一行此刻到哪了（送不到 Mac、已答、没送到）。
    private func answers(_ values: [PiAnswerValue], numbered: Bool = false, other: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            chips {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    chip(value, number: numbered && index < 9 ? index + 1 : nil)
                }
            }
            // 送不到 Mac 时不让答：写进去的请求会一直停在送达中
            .disabled(answering || !services.reachesPiHost)
            if other { Text("都不是？在下面的回复框里写你的回答").font(Typography.meta).foregroundStyle(palette.ink3) }
            if let note { Text(note.text).font(Typography.meta).foregroundStyle(note.failed ? palette.failure : palette.ink3).multilineTextAlignment(.trailing) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        #if os(macOS)
        .focusable(numbered)
        .focusEffectDisabled()
        .focused($keyboard)
        .onAppear { keyboard = numbered }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard numbered, let number = Int(press.characters), values.indices.contains(number - 1), !answering, services.reachesPiHost else { return .ignored }
            answer(values[number - 1])
            return .handled
        }
        #endif
    }

    private var note: (text: String, failed: Bool)? {
        if !services.reachesPiHost { return (String(localized: "\(SyncSummary(services.syncStatus).title)，现在答不了；同步恢复后再答，或在 Mac 上回答"), false) }
        if answering, sent == .delivered { return (String(localized: "已答，等 Mac 上的 Agent 继续"), false) }
        return failure.map { ($0, true) }
    }

    private func chip(_ value: PiAnswerValue, number: Int?) -> some View {
        let busy = answering && tapped == value
        return Button { answer(value) } label: {
            HStack(spacing: 6) {
                if busy {
                    Spinner(.small)
                    Text("送达中")
                } else {
                    #if os(macOS)
                    if let number { Keycap(text: "\(number)").accessibilityHidden(true) }
                    #endif
                    Text(value.label).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: Self.minWidth)
        }
        .buttonStyle(ControlButtonStyle(kind: .secondary))
        .accessibilityLabel(busy ? String(localized: "\(value.label)，送达中") : value.label)
    }

    /// 胶囊至少这么宽："否""是"这类一个字的不缩成一颗圆点。
    private static let minWidth: CGFloat = 32

    /// 写一条作答请求给会话所在的 Mac；写不进去时就地说明。
    private func answer(_ value: PiAnswerValue) {
        guard services.reachesPiHost, let promptID = question?.promptID else { return }
        withAnimation(HandOff.quick) { pending = Pending(promptID: promptID, value: value) }
        Task {
            do {
                let id = try await workspace.services.answer(value, to: session).id
                if pending?.promptID == promptID { pending?.requestID = id }
            } catch {
                if pending?.promptID == promptID { pending?.error = error.localizedDescription }
            }
        }
    }
}

/// 会话在问的文字题怎么答（`WaitAnswer`）：一行回答框，草稿就是会话页回复框那一份（`AppSettings.replyDraft`，两处写的是同一句），发出同会话页的作答
/// （`Workspace.speak`：会话在等 CuePad 答得了的提问时这句就是答案，选项写原文或序号）；只发文字，草稿里的卡片与图片留给会话页。
/// 同步到不了 Mac 时不能发（同回复框）。
private struct WaitReply: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var box: Binding<ComposerDraft> { services.settings.replyDraftBinding(for: session.id) }
    private var canSend: Bool { services.reachesPiHost && !box.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // 一行时字与发送钮同一条中线（字的格至少与钮同高、竖直居中）；写成几行长高时钮贴在最后一行旁（底对齐，上下边距让最后一行对着钮的中线）
        HStack(alignment: .bottom, spacing: 6) {
            TextField(String(localized: "回答"), text: box.text, palette: palette, axis: .vertical)
                .textFieldStyle(.plain).font(Typography.secondary).lineLimit(1...4)
                .padding(.vertical, Self.textInset)
                .frame(minHeight: ComposerMetrics.glyphTarget)
                .onSubmit(send)
            Button(action: send) { SendGlyph(canSend ? .ready : .idle) }
                .buttonStyle(PressStyle(.button))
                .disabled(!canSend)
                .accessibilityLabel("回答")
        }
        .padding(.leading, 12).padding(.trailing, 3).padding(.vertical, 3)
        .background(palette.fill, in: .rect(cornerRadius: 18, style: .continuous))
    }

    /// 字上下各让出的空：一行字（约 16）加两边正好是钮的点按高，多行时最后一行仍落在钮的中线附近。
    private static let textInset: CGFloat = 12

    private func send() {
        guard canSend else { return }
        _ = workspace.speak(to: .session(session, mode: .send), from: box, keeping: { var kept = $0; kept.text = ""; return kept }) { draft in
            draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
