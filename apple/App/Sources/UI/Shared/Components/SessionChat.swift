import CueStore
import SwiftUI
#if os(macOS)
import CuePi
#endif

/// 会话页的对话区（iOS 会话页、Mac 会话页共用）：滚动区（`ChatScroll`）里只排最近几条的对话（`PiConversation`），
/// 离最早那头不到一屏时（往上翻、或排开的几条铺不满一屏）再排开一段；正在请 Mac 补写对话时最上面一行说明；右缘的刻度滑条跳到你的某句话，跳到后描一圈。先描圈、
/// 排开（那句所在的段排成真的），下一次更新再跳：同一次更新里跳，目标还不在滚动区里。
struct SessionChat: View {
    let session: PiSessionState
    let digest: SessionDigest
    let readingWidth: CGFloat
    let inset: CGFloat
    @Binding var follow: ChatFollow
    /// 刻度滑条离右缘多远（Mac 让开窗口右缘的系统滚动条）。
    var scrubberInset: CGFloat = 0
    #if os(macOS)
    /// 本机在线时它在桥上的那一格：对话末尾逐字显示正在说的话（`PiConversation.slot`）。
    var slot: PiBridge.Slot?
    #endif
    @State private var window = PiConversation.firstWindow
    @State private var highlight = ChatHighlight()
    @State private var derived = ChatDerived()
    @State private var pendingJump: UUID?
    @Environment(\.palette) private var palette

    var body: some View {
        let _ = derived.refresh(digest)
        let followKey = PiConversation.followKey(session: session, messages: digest.messages, previews: digest.previews, deliveries: digest.deliveries)
        ChatScroll(followKey: followKey, readingWidth: readingWidth, inset: inset, follow: $follow) {
            VStack(spacing: 14) {
                if digest.fetchingTranscript {
                    Label("正在从 Mac 取对话…", systemImage: "arrow.down.circle").font(Typography.meta).foregroundStyle(palette.ink3)
                }
                conversation
            }
        }
        .environment(\.chatHighlight, highlight.id)
        .overlay(alignment: .trailing) { scrubber }
        .onChange(of: follow.nearOldest, initial: true) { _, near in if near { showEarlier() } }
        .onChange(of: follow.seeking) { if let id = follow.seeking?.id { seek(id) } }
        .onChange(of: pendingJump) {
            guard let id = pendingJump else { return }
            pendingJump = nil
            follow.jump(to: id)
        }
    }

    private var conversation: PiConversation {
        var conversation = PiConversation(
            session: session, items: derived.items, messages: digest.messages, deliveries: digest.deliveries, window: window, showEarlier: showEarlier)
        #if os(macOS)
        conversation.slot = slot
        #endif
        return conversation
    }

    @ViewBuilder private var scrubber: some View {
        if !derived.marks.isEmpty {
            ChatScrubber(marks: derived.marks, scrolling: follow.scrolling) { follow.seek($0) }
                .padding(.trailing, scrubberInset)
        }
    }

    /// 先描圈、排开：那条所在的段这一下才排成真的（离屏远的段是空白，`PiConversation`），排好了再跳。
    private func seek(_ id: UUID) {
        highlight.flash(id)
        window = max(window, PiConversation.window(reaching: id, in: derived.items) ?? 0)
        pendingJump = id
    }

    /// 在上面再排开一段，正在读的不动（`ChatFollow.willPrepend`）。都排开了就什么也不做。
    private func showEarlier() {
        let count = derived.items.count
        guard window < count else { return }
        let first = PiConversation.firstSegment(count: count, window: window + PiConversation.segment) * PiConversation.segment
        DebugHooks.chatShowsEarlier(from: first, of: count)
        follow.willPrepend()
        window += PiConversation.segment
    }
}
