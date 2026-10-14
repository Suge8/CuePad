import CueStore
import SwiftUI
#if os(macOS)
import CuePi
#endif

/// 会话页的对话区（iOS 会话页、Mac 会话页共用）：对话区的排开、跳转与刻度见 `ChatColumn`（与 Cue 页同一个），这里只接会话的数据——
/// 对话（`PiConversation`，按段排），正在请 Mac 补写对话时最上面一行说明。
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
    @Environment(\.palette) private var palette

    var body: some View {
        let _ = derived.refresh(digest)
        let items = derived.items
        ChatColumn(
            followKey: PiConversation.followKey(session: session, messages: digest.messages, previews: digest.previews, deliveries: digest.deliveries),
            readingWidth: readingWidth, inset: inset, follow: $follow, marks: derived.marks, count: items.count,
            position: { id in items.firstIndex { $0.id == id } }, paging: PiConversation.paging
        ) { window, showEarlier in
            VStack(spacing: 14) {
                if digest.fetchingTranscript {
                    Label("正在从 Mac 取对话…", systemImage: "arrow.down.circle").font(Typography.meta).foregroundStyle(palette.ink3)
                }
                conversation(window: window, showEarlier: showEarlier)
            }
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
