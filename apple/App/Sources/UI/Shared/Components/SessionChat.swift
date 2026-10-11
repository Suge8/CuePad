import CueStore
import SwiftUI

/// 会话页的对话区（iOS 会话页、Mac 会话页共用）：滚动区（`ChatScroll`）里只排最近几条的对话（`PiConversation`），
/// 离最早那头不到一屏时（往上翻、或排开的几条铺不满一屏）再排开一段；正在请 Mac 补写对话时最上面一行说明；右缘的刻度滑条跳到你的某句话，跳到后描一圈。那句还没排开时先排开，
/// 排开之后再跳：同一次更新里跳，目标还不在滚动区里。
struct SessionChat: View {
    let session: PiSessionState
    let digest: SessionDigest
    let readingWidth: CGFloat
    let inset: CGFloat
    @Binding var follow: ChatFollow
    /// 刻度滑条离右缘多远（Mac 让开窗口右缘的系统滚动条）。
    var scrubberInset: CGFloat = 0
    @State private var window = PiConversation.firstWindow
    @State private var highlight = ChatHighlight()
    @State private var pendingJump: UUID?
    @Environment(\.palette) private var palette

    var body: some View {
        let followKey = PiConversation.followKey(session: session, messages: digest.messages, previews: digest.previews, deliveries: digest.deliveries)
        ChatScroll(followKey: followKey, readingWidth: readingWidth, inset: inset, follow: $follow) {
            VStack(spacing: 14) {
                if digest.fetchingTranscript {
                    Label("正在从 Mac 取对话…", systemImage: "arrow.down.circle").font(Typography.meta).foregroundStyle(palette.ink3)
                }
                PiConversation(
                    session: session, messages: digest.messages, previews: digest.previews, deliveries: digest.deliveries, window: window,
                    showEarlier: showEarlier)
            }
        }
        .environment(\.chatHighlight, highlight.id)
        .overlay(alignment: .trailing) { scrubber }
        .onChange(of: follow.nearOldest, initial: true) { _, near in if near { showEarlier() } }
        .onChange(of: window) {
            guard let id = pendingJump else { return }
            pendingJump = nil
            jump(to: id)
        }
    }

    @ViewBuilder private var scrubber: some View {
        let marks = ChatScrubber.marks(PiChat.entries(digest.messages, previews: digest.previews))
        if !marks.isEmpty {
            ChatScrubber(marks: marks, scrolling: follow.scrolling) { id in
                let needed = PiConversation.window(reaching: id, messages: digest.messages, previews: digest.previews) ?? 0
                if needed > window {
                    pendingJump = id
                    window = needed
                } else {
                    jump(to: id)
                }
            }
            .padding(.trailing, scrubberInset)
        }
    }

    /// 在上面再排开一段，正在读的不动（`ChatFollow.willPrepend`）。都排开了就什么也不做。
    private func showEarlier() {
        let count = ChatItem.of(PiChat.entries(digest.messages, previews: digest.previews)).count
        guard window < count else { return }
        let first = PiConversation.firstSegment(count: count, window: window + PiConversation.segment) * PiConversation.segment
        DebugHooks.chatShowsEarlier(from: first, of: count)
        follow.willPrepend()
        window += PiConversation.segment
    }

    private func jump(to id: UUID) {
        follow.jump(to: id)
        highlight.flash(id)
    }
}
