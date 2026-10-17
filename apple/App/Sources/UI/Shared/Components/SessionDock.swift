import CueStore
import SwiftUI

/// 会话页底下浮着的那一叠（手机的会话页与 Mac 的会话页同一份）：等你确认时的问题卡、没能结束的原因（与 Agent 页同一条规则
/// `DeliveryRequest.shownEnd`）、回复框（`PiReplyBar`）；回复框的停止中、命令进度、发送中、排队与调回的那一句都从这一页读到的会话摘要推出。
/// 读到会话记录、确认它不在了（Mac 上的会话文件被删）时，回复框换成一句说明。
struct SessionDock: View {
    let session: PiSessionState
    /// 这一页读到的会话摘要；还没读到为 nil。
    let digest: SessionDigest?
    /// 在看历史：回复框收成短胶囊（只有手机这样）。
    var compact = false
    var revealNote: (ReplyNote) -> Void = { _ in }
    let sent: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let deliveries = digest?.deliveries ?? [], messages = digest?.messages ?? [], speech = services.speech
        VStack(spacing: 8) {
            PiQuestionDock(session: session, deliveries: deliveries)
            if let failure = DeliveryRequest.shownEnd(in: deliveries, at: speech)?.failure, session.state != .known(.ended) {
                Callout(.failed, text: "没能结束：\(failure.text(sync: services.syncStatus))", docked: true)
            }
            if let digest, digest.session == nil {
                Text("这个会话已经不在了，发不到它").font(.footnote).foregroundStyle(palette.ink3)
            } else {
                PiReplyBar(
                    session: session, config: digest?.config(at: speech), catalog: digest?.catalog, compact: compact,
                    stopping: MacDelivery.stopping(session, deliveries: deliveries, at: speech),
                    commandProgress: MacDelivery.commandProgress(deliveries, messages: messages, at: speech),
                    sending: PiChat.sending(deliveries, messages: messages, at: speech),
                    queued: PiChat.queued(deliveries, messages: messages, at: speech),
                    recall: PiChat.lastSaid(messages),
                    revealNote: revealNote,
                    sent: sent)
            }
        }
    }
}

extension View {
    /// 很久以前的会话没有对话：读到这一页后请它所在的 Mac 补写一次（本机的也走同一条路；同步不通时不请；
    /// 已有没被领取的补写请求时不写第二条，`CueStore.requestTranscript`）。
    func requestsTranscript(_ digest: SessionDigest?) -> some View { modifier(TranscriptRequest(digest: digest)) }
}

private struct TranscriptRequest: ViewModifier {
    let digest: SessionDigest?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var asked = false

    func body(content: Content) -> some View {
        content.onChange(of: digest, initial: true) {
            guard !asked, let digest, let session = digest.session, services.reachesPiHost,
                  PiChat.needsTranscript(session, messages: digest.messages) else { return }
            asked = true
            workspace.attempt { _ = try await services.requestTranscript(of: session) }
        }
    }
}
