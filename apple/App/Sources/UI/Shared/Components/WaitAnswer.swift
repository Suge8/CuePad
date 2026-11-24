import CueStore
import SwiftUI

struct WaitAnswer: View {
    let session: SessionState
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

    private var request: DeliveryRequest? { services.sessionFeed.answer(to: session) }

    private var unseen: Pending? {
        guard let pending, pending.promptID == question?.promptID, pending.requestID == nil || pending.requestID != request?.id else { return nil }
        return pending
    }

    private var tapped: AnswerValue? { unseen.map(\.value) ?? request?.answer?.value }
    private var writeError: String? { unseen?.error }
    private var sent: Speech.Trip? { unseen == nil ? request.map { Speech.trip($0, at: services.speech) } : nil }

    private var answering: Bool { tapped != nil && writeError == nil && sent?.failure == nil }
    private var failure: String? { writeError ?? sent?.failure?.text }

    var body: some View {
        switch question?.kind.known {
        case .confirm: answers([.confirmed(false), .confirmed(true)])
        case .select: answers((question?.options ?? []).map(AnswerValue.option), other: question?.allowsOther == true)
        case .text, nil: EmptyView()
        }
    }

    private func answers(_ values: [AnswerValue], other: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.tight) {
            ChipFlow {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    chip(value, number: index < 9 ? index + 1 : nil)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .disabled(answering)
            if other { Text("都不是？在下面的回复框里写你的回答").font(Typography.meta).foregroundStyle(palette.ink3) }
            Text(note?.text ?? " ").font(Typography.meta).foregroundStyle(note?.failed == true ? palette.failure : palette.ink3).lineLimit(1)
                .opacity(note == nil ? 0 : 1).readerHidden(note == nil)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .focused($keyboard)
        .yieldsFocusWhenCovered($keyboard)
        .onAppear { keyboard = !covered }
        .onKeyPress(characters: .decimalDigits, phases: .down) { press in
            guard let number = Int(press.characters), values.indices.contains(number - 1), !answering else { return .ignored }
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
