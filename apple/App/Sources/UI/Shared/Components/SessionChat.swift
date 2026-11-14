import CueStore
import SwiftUI
#if os(macOS)
import CueBridge
#endif

/// 会话所在的 Mac 不是本机、本机正在和 iCloud 对时，到的先不滑上来（`ChatScroll`）。
struct SessionChat: View {
    let session: SessionState
    let digest: SessionDigest
    let readingWidth: CGFloat
    let inset: CGFloat
    @Binding var follow: ChatFollow
    #if os(macOS)
    var slot: Bridge.Slot?
    #endif
    @State private var derived = ChatDerived()
    @Environment(AppServices.self) private var services

    var body: some View {
        let _ = derived.refresh(digest, at: services.speech)
        let items = derived.items
        ChatColumn(
            followKey: Conversation.followKey(
                session: session, messages: digest.messages, previews: digest.previews, deliveries: digest.deliveries, at: services.speech),
            readingWidth: readingWidth, inset: inset, follow: $follow, marks: derived.marks, ids: items.map(\.id),
            paging: Conversation.paging,
            holding: services.syncing.isCatchingUp(on: session.hostID)
        ) { window in
            conversation(window: window)
        }
        .overlay {
            BlankChat(shown: items.isEmpty && digest.deliveries.isEmpty && !session.hasStarted && session.state != .known(.ended)
                && session.pendingPrompt == nil && session.lastPrompt == nil, readingWidth: readingWidth, inset: inset)
        }
    }

    private func conversation(window: ChatWindow) -> Conversation {
        var conversation = Conversation(
            session: session, items: derived.items, messages: digest.messages, window: window,
            fetching: digest.fetchingTranscript(at: services.speech))
        #if os(macOS)
        conversation.slot = slot
        #endif
        return conversation
    }
}
