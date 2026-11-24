import CueStore
import SwiftUI

struct SessionDock: View {
    let session: SessionState
    let digest: SessionDigest?
    let chat: ChatDerived.Facts
    var revealNote: (ReplyNote) -> Void = { _ in }
    let sent: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let deliveries = digest?.deliveries ?? [], messages = digest?.messages ?? [], speech = services.speech
        let endIssue = MacDelivery.endProgress(deliveries, at: speech), config = digest?.config(at: speech)
        VStack(spacing: 0) {
            QuestionDock(session: session)
            FailureDock(session: session, delivery: digest?.delivery, catalog: digest?.catalog, config: config)
            DockedCard(endIssue?.unconfirmedReason) { reason in
                Callout(.unknown, text: String(localized: "休眠结果尚未确认：\(reason)"), docked: true) { recoverEnd }
            }
            DockedCard(endIssue?.failure?.text) { failure in
                Callout(.failed(.other), text: String(localized: "没能休眠：\(failure)"), docked: true) { recoverEnd }
            }
            if let digest, digest.session == nil {
                Text("这个会话已经不在了，发不到它").font(Typography.meta).foregroundStyle(palette.ink3)
            } else {
                ReplyBar(
                    session: session, config: config, catalog: digest?.catalog,
                    stopping: MacDelivery.stopping(session, deliveries: deliveries, at: speech),
                    commandProgress: MacDelivery.commandProgress(deliveries, messages: messages, at: speech),
                    sending: chat.sending,
                    recall: chat.lastSaid,
                    previews: digest?.previews ?? [],
                    cache: messages.last { $0.role == .known(.pi) }?.tools?.cache,
                    revealNote: revealNote,
                    sent: sent)
            }
        }
    }
    private var recoverEnd: some View {
        Group {
            if let action = SessionActions.sleep(session, ending: false, recovering: true, in: workspace) {
                Button(action.title, icon: action.icon, action: action.run)
                    .buttonStyle(ControlButtonStyle(kind: .secondary))
            }
        }
    }
}

extension View {
    func requestsTranscript(_ digest: SessionDigest?) -> some View { modifier(TranscriptRequest(digest: digest)) }
}

private struct TranscriptRequest: ViewModifier {
    let digest: SessionDigest?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var asked = false

    func body(content: Content) -> some View {
        content.onChange(of: digest, initial: true) {
            guard !asked, let digest, let session = digest.session, services.syncing.reachesHost,
                  Chat.needsTranscript(session, messages: digest.messages) else { return }
            asked = true
            workspace.attempt { _ = try await services.requestTranscript(of: session) }
        }
    }
}
