import SwiftUI

/// 对话页的对话区（会话页与 Cue 页、Mac 与 iPhone 同一个）：滚动区（`ChatScroll`）里只排最近 `window` 条，离最早那头不到一屏时
/// （往上翻、或排开的几条铺不满一屏）再排开 `paging.step` 条；右缘的刻度滑条（`ChatScrubber`）与内容里的 `chatJump` 跳到某一条，跳到后描一圈（`chatHighlight`）。
/// 先描圈、排开（那条所在的地方排成真的），下一次更新再跳：同一次更新里跳，目标还不在滚动区里。
/// 内容只管按 `window` 排哪几条、它们长什么样；排开、跳转、描圈与刻度都在这里。
struct ChatColumn<Content: View, Key: Equatable>: View {
    let followKey: Key
    let readingWidth: CGFloat
    let inset: CGFloat
    @Binding var follow: ChatFollow
    /// 刻度：你说的话与换上下文的地方（先后）。
    let marks: [ChatMark]
    /// 对话里一共几条，与 `position` 给的序号同一种数法。
    let count: Int
    /// 某一条在对话里的序号（从最早那条数起）；跳到它要排开到那里。
    let position: (UUID) -> Int?
    let paging: ChatPaging
    @ViewBuilder let content: (_ window: Int, _ showEarlier: @escaping () -> Void) -> Content
    @State private var window: Int
    @State private var highlight = ChatHighlight()
    @State private var pendingJump: UUID?

    init(
        followKey: Key, readingWidth: CGFloat, inset: CGFloat, follow: Binding<ChatFollow>, marks: [ChatMark], count: Int,
        position: @escaping (UUID) -> Int?, paging: ChatPaging,
        @ViewBuilder content: @escaping (_ window: Int, _ showEarlier: @escaping () -> Void) -> Content
    ) {
        self.followKey = followKey
        self.readingWidth = readingWidth
        self.inset = inset
        _follow = follow
        self.marks = marks
        self.count = count
        self.position = position
        self.paging = paging
        self.content = content
        _window = State(initialValue: paging.first)
    }

    var body: some View {
        ChatScroll(followKey: followKey, readingWidth: readingWidth, inset: inset, follow: $follow) {
            content(window, showEarlier)
        }
        .environment(\.chatHighlight, highlight.id)
        .environment(\.chatJump) { follow.seek($0) }
        .overlay(alignment: .trailing) {
            if !marks.isEmpty {
                ChatScrubber(marks: marks, scrolling: follow.scrolling) { follow.seek($0) }
                    .padding(.trailing, Self.scrollerWidth)
            }
        }
        .onChange(of: follow.nearOldest, initial: true) { _, near in if near { showEarlier() } }
        .onChange(of: follow.seeking) { if let id = follow.seeking?.id { seek(id) } }
        .onChange(of: pendingJump) {
            guard let id = pendingJump else { return }
            pendingJump = nil
            follow.jump(to: id)
        }
    }

    /// 刻度滑条让开的系统滚动条宽：Mac 窗口右缘的悬浮滚动条（手机上的滚动指示条由滑条自己让，见 `ChatScrubber.edge`）。
    #if os(macOS)
    private static var scrollerWidth: CGFloat { 16 }
    #else
    private static var scrollerWidth: CGFloat { 0 }
    #endif

    /// 先描圈、排开到那一条（离屏远的地方排的是空白，描圈的那条所在的段排成真的），排好了再跳。
    private func seek(_ id: UUID) {
        highlight.flash(id)
        if let index = position(id) { window = max(window, count - index) }
        pendingJump = id
    }

    /// 在上面再排开一段，正在读的不动（`ChatFollow.willPrepend`）。都排开了就什么也不做。
    private func showEarlier() {
        guard window < count else { return }
        DebugHooks.chatShowsEarlier(from: max(0, count - window - paging.step), of: count)
        follow.willPrepend()
        window += paging.step
    }
}

/// 对话一开始排开最近几条、每次往上再排开几条。
nonisolated struct ChatPaging: Equatable {
    let first: Int
    let step: Int
}
