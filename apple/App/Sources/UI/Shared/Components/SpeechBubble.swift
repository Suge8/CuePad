import CueStore
import SwiftUI

struct SpeechBubble<Menu: View>: View {
    let said: Said
    let box: Binding<ComposerDraft>
    var showsDelivered = true
    var session: SessionState?
    var fromCue = false
    var marksTransit = true
    let look: BubbleLook
    @ViewBuilder var menu: (Speech.Trip) -> Menu
    @State private var confirmingAgain = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        let trip = said.trip(at: services.speech), shown = bubble(trip)
        VStack(alignment: .trailing, spacing: look.statusSpacing) {
            UserBubble(stored: said.content, look: look, trip: shown, highlighted: highlight == said.id, fromCue: fromCue, marksTransit: marksTransit) { menu(trip) }
            if case .preparing(let reason) = trip {
                VStack(alignment: .trailing, spacing: Spacing.tight) {
                    Text(verbatim: reason)
                    Button("撤回", action: remove).buttonStyle(PressStyle(.inline))
                }
                .font(Typography.caption).foregroundStyle(palette.ink3).padding(.trailing, look.statusInset)
            } else if let reason = trip.unconfirmedReason {
                VStack(alignment: .trailing, spacing: Spacing.tight) {
                    Text(verbatim: reason)
                    Button("再说一次…") { confirmingAgain = true }.buttonStyle(PressStyle(.inline))
                }
                .font(Typography.caption).foregroundStyle(palette.ink3).padding(.trailing, look.statusInset)
            } else if case .failed(let undelivered) = shown { failedLine(undelivered).padding(.trailing, look.statusInset) }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .transition(.entry)
        .dialog("再说一次？", isPresented: $confirmingAgain, message: "上一句可能已经执行，再说一次可能让 Agent 重复操作。原请求会保留。", buttons: [
            DialogButton(title: "再说一次") { workspace.sayAgain(said, restoringInto: box) },
        ])
    }

    private func bubble(_ trip: Speech.Trip) -> BubbleTrip {
        switch trip {
        case .sending, .sent:
            if case .request(let request) = said { .sending(.of(request, session: session, trip: trip)) } else { .sending(trip == .sent ? .sent : .sending) }
        case .preparing: .arrived
        case .unconfirmed: .sending(.unconfirmed)
        case .delivered: showsDelivered ? .delivered(said.roundTrip.map { SessionClock.duration(Double($0.components.seconds)) }) : .arrived
        case .failed(let failure):
            .failed(Undelivered(reason: failure.text, resend: resend, remove: remove))
        }
    }

    private func failedLine(_ undelivered: Undelivered) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.tight) {
            Text(verbatim: undelivered.reason)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 0) {
                Text("未送达，")
                Button(MessageMenu.Item.resend.title, action: undelivered.resend)
                    .fontWeight(.semibold)
                    .buttonStyle(PressStyle(.inline))
                    .contentShape(.rect.inset(by: -14))
            }
        }
        .font(Typography.caption).foregroundStyle(palette.failure)
    }

    private func resend() { workspace.resend(said, restoringInto: box) }
    private func remove() { workspace.remove(said) }
}

nonisolated extension Speech.Failure {
    var text: String { switch self { case .reported(let reason): reason } }
}
