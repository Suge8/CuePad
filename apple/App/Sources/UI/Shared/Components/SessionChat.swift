import CueStore
import SwiftUI
#if os(macOS)
import CuePi
#endif

/// 会话页的对话区（iOS 会话页、Mac 会话页共用）：对话区的排开、跳转与刻度见 `ChatColumn`（与 Cue 页同一个），这里只接会话的数据——
/// 对话（`PiConversation`，按段排），正在请 Mac 补写对话时最上面一行说明，还没说过话时叠一层空态（`BlankChat`）。会话所在的 Mac 不是本机、本机正在和 iCloud 对时，到的先不滑上来（`ChatScroll`）。
struct SessionChat: View {
    let session: PiSessionState
    let digest: SessionDigest
    let readingWidth: CGFloat
    let inset: CGFloat
    @Binding var follow: ChatFollow
    #if os(macOS)
    /// 本机在线时它在桥上的那一格：对话末尾逐字显示正在说的话（`PiConversation.slot`）。
    var slot: PiBridge.Slot?
    #endif
    @State private var derived = ChatDerived()
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let _ = derived.refresh(digest)
        let items = derived.items
        ChatColumn(
            followKey: PiConversation.followKey(
                session: session, messages: digest.messages, previews: digest.previews, deliveries: digest.deliveries, at: services.speech),
            readingWidth: readingWidth, inset: inset, follow: $follow, marks: derived.marks, ids: items.map(\.id),
            paging: PiConversation.paging,
            holding: services.isCatchingUp(on: session.hostID)
        ) { window, showEarlier in
            VStack(spacing: 14) {
                if digest.fetchingTranscript(at: services.speech) {
                    Label("正在从 Mac 取对话…", icon: .fetching).font(Typography.meta).foregroundStyle(palette.ink3)
                }
                conversation(window: window, showEarlier: showEarlier)
            }
        }
        .overlay {
            BlankChat(shown: items.isEmpty && digest.deliveries.isEmpty && !session.hasStarted && session.state != .known(.ended)
                && session.pendingPrompt == nil && session.lastPrompt == nil, readingWidth: readingWidth, inset: inset)
        }
    }

    private func conversation(window: Int, showEarlier: @escaping () -> Void) -> PiConversation {
        var conversation = PiConversation(
            session: session, items: derived.items, messages: digest.messages, deliveries: digest.deliveries, window: window, showEarlier: showEarlier)
        #if os(macOS)
        conversation.slot = slot
        #endif
        return conversation
    }
}
