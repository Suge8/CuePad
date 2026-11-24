import CueStore
import SwiftUI
#if os(macOS)
import CueBridge
#endif

struct SessionChat: View {
    let session: SessionState
    let digest: SessionDigest
    let readingWidth: CGFloat
    let inset: CGFloat
    let chat: ChatDerived.Facts
    @Binding var follow: ChatFollow
    #if os(macOS)
    var slot: Bridge.Slot?
    #endif
    @Environment(AppServices.self) private var services

    var body: some View {
        let items = chat.items
        ChatColumn(
            followKey: Conversation.FollowKey(messages: digest.messages.count, previews: digest.previews.count, outgoing: chat.trips, state: session.state),
            readingWidth: readingWidth, inset: inset, follow: $follow, marks: chat.marks, ids: items.map(\.id),
            paging: Conversation.paging,
            holding: services.syncing.isCatchingUp(on: session.hostID)
        ) { window in
            conversation(window: window).equatable()
        }
        .overlay {
            BlankChat(shown: items.isEmpty && digest.deliveries.isEmpty && !session.hasStarted && session.state != .known(.ended)
                && session.pendingPrompt == nil && session.lastPrompt == nil, readingWidth: readingWidth, inset: inset)
        }
    }

    private func conversation(window: ChatWindow) -> Conversation {
        var conversation = Conversation(
            session: session, items: chat.items, messages: digest.messages, window: window,
            fetching: digest.fetchingTranscript(at: services.speech))
        #if os(macOS)
        conversation.slot = slot
        #endif
        return conversation
    }
}
