import CueStore
import SwiftUI

/// 读到会话记录、确认它不在了（Mac 上的会话文件被删）时，回复框换成一句说明。
struct SessionDock: View {
    let session: SessionState
    let digest: SessionDigest?
    var compact = false
    var revealNote: (ReplyNote) -> Void = { _ in }
    let sent: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let deliveries = digest?.deliveries ?? [], messages = digest?.messages ?? [], speech = services.speech
        let endIssue = MacDelivery.endIssue(deliveries, at: speech)
        // 卡与回复框之间的缝在卡里（`DockedCard`）：卡升起、沉回时缝跟着长、跟着收
        VStack(spacing: 0) {
            QuestionDock(session: session)
            FailureDock(session: session, delivery: digest?.delivery, catalog: digest?.catalog, config: digest?.config(at: speech))
            DockedCard(endIssue?.unconfirmedReason) { reason in
                Callout(.unknown(), text: String(localized: "结束结果尚未确认：\(reason)"), docked: true) { recoverEnd }
            }
            DockedCard(endIssue?.failure?.text) { failure in
                Callout(.failed(.other), text: String(localized: "没能结束：\(failure)"), docked: true) { recoverEnd }
            }
            if let digest, digest.session == nil {
                Text("这个会话已经不在了，发不到它").font(Typography.meta).foregroundStyle(palette.ink3)
            } else {
                ReplyBar(
                    session: session, config: digest?.config(at: speech), catalog: digest?.catalog, compact: compact,
                    stopping: MacDelivery.stopping(session, deliveries: deliveries, at: speech),
                    commandProgress: MacDelivery.commandProgress(deliveries, messages: messages, at: speech),
                    sending: Chat.sending(deliveries, messages: messages, at: speech),
                    recall: Chat.lastSaid(messages),
                    previews: digest?.previews ?? [],
                    revealNote: revealNote,
                    sent: sent)
            }
        }
    }
    private var recoverEnd: some View {
        Group {
            if let action = SessionActions.end(session, ending: false, recovering: true, in: workspace) {
                Button(action.title, icon: action.icon, action: action.run)
                    .buttonStyle(ControlButtonStyle(kind: .secondary))
            }
        }
    }
}

extension View {
    /// 本机的也走同一条路；同步不通时不请；已有没被领取的补写请求时不写第二条（`CueStore.requestTranscript`）。
    func requestsTranscript(_ digest: SessionDigest?) -> some View { modifier(TranscriptRequest(digest: digest)) }
}

private struct TranscriptRequest: ViewModifier {
    let digest: SessionDigest?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var asked = false

    func body(content: Content) -> some View {
        content.onChange(of: digest, initial: true) {
            guard !asked, let digest, let session = digest.session, services.reachesHost,
                  Chat.needsTranscript(session, messages: digest.messages) else { return }
            asked = true
            workspace.attempt { _ = try await services.requestTranscript(of: session) }
        }
    }
}
