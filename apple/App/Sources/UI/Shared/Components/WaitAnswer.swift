import CueStore
import SwiftUI

/// Cue 的提问里"可以"是全件唯一的靛青。进展页等你列的卡上也用它答（`leading`：选项靠左排，卡脚在它下面）。
/// 选项不写进问句，也不给自由回答框（会话页上允许自己写的，提示在底下回复框里写）；长选项折行写全。
/// 确认题"否 / 是"两颗普通胶囊：确认的常是部署、覆盖这类撤不回的事，不用主色推着人点"是"。
/// 到哪了读库里答这道题（`promptID`）的那条请求，不记在视图里：切到别的卡再回来照样在，会话换了下一道题就是新的一题。
/// 同步到不了 Mac 时照样答：作答写下就排着，恢复后自动发出（同回复框）。Mac 的会话页上选择题按 1–9 直接作答（键帽在胶囊里）。
struct WaitAnswer: View {
    let wait: CueTally.Wait
    var replyElsewhere = false
    /// 选项靠左排、到哪了那一行有才占位（看板的卡；Cue 页的卡靠右、一直占着）。
    var leading = false
    @Environment(Workspace.self) private var workspace
    @State private var ending = false

    var body: some View {
        switch wait {
        case .message(let message, _):
            CueChoices(message: message, disabled: ending, pick: { choice in end { try await $0.answerCueQuestion(message.id, choice) } }) {
                end { try await $0.declineCueQuestion(message.id) }
            }
        case .session(let session, _):
            SessionAnswer(session: session, replyElsewhere: replyElsewhere, leading: leading)
        }
    }
}

extension WaitAnswer {
    private func end(_ write: @escaping (AppServices) async throws -> Void) {
        ending = true
        workspace.attempt {
            defer { ending = false }
            try await write(workspace.services)
        }
    }
}

private struct SessionAnswer: View {
    let session: SessionState
    let replyElsewhere: Bool
    let leading: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var pending: Pending?
    #if os(macOS)
    @FocusState private var keyboard: Bool
    @Environment(\.panelCovered) private var covered
    #endif

    private var question: Question? { session.answerableQuestion }

    private struct Pending {
        let promptID: String
        let value: AnswerValue
        var requestID: UUID?
        var error: String?
    }

    private var request: DeliveryRequest? { services.liveSessions.answer(to: session) }

    private var unseen: Pending? {
        guard let pending, pending.promptID == question?.promptID, pending.requestID == nil || pending.requestID != request?.id else { return nil }
        return pending
    }

    private var tapped: AnswerValue? { unseen.map(\.value) ?? request?.answer?.value }
    private var writeError: String? { unseen?.error }
    private var sent: Speech.Trip? { unseen == nil ? request.map { Speech.trip($0, at: services.speech) } : nil }

    /// 点下即算在答（请求写成前也是），胶囊立刻停用，不重复作答。
    private var answering: Bool { tapped != nil && writeError == nil && sent?.failure == nil }
    private var failure: String? { writeError ?? sent?.failure?.text }

    var body: some View {
        switch question?.kind.known {
        case .confirm: answers([.confirmed(false), .confirmed(true)])
        case .select:
            answers((question?.options ?? []).map(AnswerValue.option), numbered: replyElsewhere,
                    other: replyElsewhere && question?.allowsOther == true, rows: leading)
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
        ChipFlow(leading: leading) { content() }.frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
    }

    /// `rows`：一项一行、铺满卡宽、长的折行写全（看板的卡窄，长选项挤成胶囊读不了）。
    private func answers(_ values: [AnswerValue], numbered: Bool = false, other: Bool = false, rows: Bool = false) -> some View {
        VStack(alignment: leading ? .leading : .trailing, spacing: Spacing.tight) {
            Group {
                if rows {
                    VStack(spacing: Spacing.tight) { ForEach(Array(values.enumerated()), id: \.offset) { row($1) } }
                } else {
                    chips {
                        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                            chip(value, number: numbered && index < 9 ? index + 1 : nil)
                        }
                    }
                }
            }
            .disabled(answering)
            if other { Text("都不是？在下面的回复框里写你的回答").font(Typography.meta).foregroundStyle(palette.ink3) }
            // 到哪了那一行一直占着（没有时留白）、只写一行：它一出一收卡就变高变矮，浮在卡上面的对话跟着当帧跳
            if !leading || note != nil {
                Text(note?.text ?? " ").font(Typography.meta).foregroundStyle(note?.failed == true ? palette.failure : palette.ink3).lineLimit(1)
                    .opacity(note == nil ? 0 : 1).readerHidden(note == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: leading ? .leading : .trailing)
        #if os(macOS)
        .focusable(numbered)
        .focusEffectDisabled()
        .focused($keyboard)
        .yieldsFocusWhenCovered($keyboard)
        .onAppear { keyboard = numbered && !covered }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard numbered, let number = Int(press.characters), values.indices.contains(number - 1), !answering else { return .ignored }
            answer(values[number - 1])
            return .handled
        }
        #endif
    }

    private var note: (text: String, failed: Bool)? {
        if let reason = sent?.unconfirmedReason { return (reason, false) }
        if answering, sent == .delivered { return (String(localized: "已答，等 Mac 上的 Agent 继续"), false) }
        return failure.map { ($0, true) }
    }

    private func chip(_ value: AnswerValue, number: Int?) -> some View {
        let busy = answering && tapped == value
        return Button { answer(value) } label: {
            HStack(spacing: Spacing.glyph) {
                if busy {
                    Spinner(.small)
                    Text("送达中")
                } else {
                    #if os(macOS)
                    if let number { Keycap(text: "\(number)").accessibilityHidden(true) } // 合并：按钮的标签，读屏念 accessibilityLabel
                    #endif
                    Text(value.label).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(minWidth: Self.minWidth)
        }
        .buttonStyle(ControlButtonStyle(kind: .secondary))
        .accessibilityLabel(busy ? String(localized: "\(value.label)，送达中") : value.label)
    }

    private func row(_ value: AnswerValue) -> some View {
        let busy = answering && tapped == value
        return Button { answer(value) } label: {
            HStack(spacing: Spacing.glyph) {
                Text(value.label).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if busy { Spinner(.small) }
            }
            .font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink)
            .padding(.horizontal, Spacing.group).padding(.vertical, Spacing.item)
            .background(palette.paper, in: RoundedRectangle(cornerRadius: Radius.chip))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.card))
        .accessibilityLabel(busy ? String(localized: "\(value.label)，送达中") : value.label)
    }

    /// 胶囊至少这么宽："否""是"这类一个字的不缩成一颗圆点。
    private static let minWidth: CGFloat = 32

    private func answer(_ value: AnswerValue) {
        guard let promptID = question?.promptID else { return }
        withAnimation(Motion.fade) { pending = Pending(promptID: promptID, value: value) }
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

/// 草稿就是会话页回复框那一份（`AppSettings.replyDraft`，两处写的是同一句）；只发文字，草稿里的卡片与图片留给会话页。
private struct WaitReply: View {
    let session: SessionState
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var box: Binding<ComposerDraft> { services.settings.replyDraftBinding(for: session.id) }
    private var canSend: Bool { !box.wrappedValue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        // 一行时字与发送钮同一条中线（字的格至少与钮同高、竖直居中）；写成几行长高时钮贴在最后一行旁（底对齐，上下边距让最后一行对着钮的中线）
        HStack(alignment: .bottom, spacing: Spacing.glyph) {
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
        .padding(.leading, Spacing.group).padding(.trailing, Spacing.hair).padding(.vertical, Spacing.hair)
        .background(palette.fill, in: Radius.nested)
    }

    /// 字上下各让出的空：一行字（约 16）加两边正好是钮的点按高，多行时最后一行仍落在钮的中线附近。
    private static let textInset: CGFloat = 12

    private func send() {
        guard canSend else { return }
        workspace.answer(session, from: box)
    }
}
