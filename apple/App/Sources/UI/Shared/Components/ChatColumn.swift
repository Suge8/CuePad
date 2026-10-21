import SwiftUI

/// 对话页的对话区（会话页与 Cue 页、Mac 与 iPhone 同一个）：滚动区（`ChatScroll`）里只排最近几条（多少由 `paging` 按可见区的高定），
/// 离最早那头不到一屏时（往上翻、或排开的几条铺不满一屏）再排开一段。排开到哪按那一条记（`shown`），不按条数：新的在下面长出来、
/// 读的范围丢掉了最早的几条（Cue 页只读最近 `CueThread.limit` 条）时，上面已经排着的不被挤掉——挤掉的话正在看的整段一下往上窜。
/// 右缘的刻度滑条（`ChatScrubber`）与内容里的 `chatJump` 跳到某一条，跳到后描一圈（`chatHighlight`）；从新消息读起的不描（`ChatFollow.Landing`）。
/// 先描圈、排开（那条所在的地方排成真的），下一次更新再跳：同一次更新里跳，目标还不在滚动区里。
/// 内容只管按 `ChatWindow` 排哪几条、它们长什么样；排开、跳转、描圈与刻度都在这里。`holding`：本机正在和 iCloud 对，见 `ChatScroll`。
struct ChatColumn<Content: View, Key: Equatable>: View {
    let followKey: Key
    let readingWidth: CGFloat
    let inset: CGFloat
    @Binding var follow: ChatFollow
    /// 刻度：你说的话与换上下文的地方（先后）。
    let marks: [ChatMark]
    /// 对话里的各条，从最早那条起；`content` 排的是它的最后 `ChatWindow.count` 条。
    let ids: [UUID]
    let paging: ChatPaging
    let holding: Bool
    @ViewBuilder let content: (ChatWindow) -> Content
    /// 排开到的最早那一条起、记下时对话里的各条；还没排（没有内容）为 nil。连后面的一起记：那一条自己掉出了读的范围（排开到了最早那头，
    /// 来一句新的它就掉出去），从它后面还在的第一条排（`start`），不缩回一屏——缩回去内容一下矮了几屏，可见区落在内容外、整屏空白。
    /// 在同一次更新里就接上：等 `onChange` 改记已晚了一帧，那一帧缩回去又长回来，正在看的先被甩到最早那头再滑回来。
    @State private var shown: ArraySlice<UUID>?
    @State private var highlight = ChatHighlight()
    @State private var pendingJump: ChatFollow.Target?
    @State private var column = UUID()

    init(
        followKey: Key, readingWidth: CGFloat, inset: CGFloat, follow: Binding<ChatFollow>, marks: [ChatMark], ids: [UUID],
        paging: ChatPaging, holding: Bool, @ViewBuilder content: @escaping (ChatWindow) -> Content
    ) {
        self.followKey = followKey
        self.readingWidth = readingWidth
        self.inset = inset
        _follow = follow
        self.marks = marks
        self.ids = ids
        self.paging = paging
        self.holding = holding
        self.content = content
    }

    /// 排着几条：从记下的那一条到最新，至少是按可见区此刻的尺寸 `size` 铺满一屏的那么多（`paging.first`）。记下时的可见区可能还不是最终的
    /// （iPhone 冷启动时第一次排版的窗口只有图标那么大），按那时记的条数排，可见区长大的那一帧上面就空着。
    private func window(_ size: CGSize) -> Int {
        let screen = min(ids.count, paging.first(size, ids.count))
        guard let start else { return screen }
        return max(ids.count - start, screen)
    }

    /// 排开到的最早那一条此刻是第几条：它不在了是它后面还在的第一条；都不在了（或还没排）为 nil。
    private var start: Int? {
        guard let shown, let first = shown.first else { return nil }
        if let index = ids.firstIndex(of: first) { return index }
        let present = Dictionary(ids.enumerated().map { ($1, $0) }) { earlier, _ in earlier }
        return shown.lazy.compactMap { present[$0] }.first
    }

    /// 可见区的尺寸在同一次排版里拿到（GeometryReader 先拿到自己的尺寸再排里面）：打开的第一帧就按它排开，不先排一帧再补。
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size, window = self.window(size), first = ids.count - window
            ChatScroll(followKey: followKey, readingWidth: readingWidth, inset: inset, follow: $follow, holding: holding) {
                content(ChatWindow(count: window, earlier: first > 0 ? paging.step(size, first) : 0) { showEarlier(size) })
            }
            .overlay(alignment: .trailing) {
                if !marks.isEmpty {
                    let margin = ChatLayout.margin(size.width, readingWidth: readingWidth, inset: inset)
                    ChatScrubber(marks: marks, scrolling: follow.scrolling, crowded: margin < Self.scrollerWidth + ChatScrubber.room) { follow.seek($0) }
                        .padding(.trailing, Self.scrollerWidth)
                }
            }
            // 改记成接上的那条，之后不用每次再找
            .onChange(of: ids, initial: true) {
                let index = start ?? ids.count - self.window(size)
                if shown?.first != (ids.indices.contains(index) ? ids[index] : nil) { show(from: index) }
            }
            // 这一帧画上屏之后再排开：打开时读数就报着离最早那头不到一屏，同一次更新里排开的话第一帧要多排一屏
            .onChange(of: follow.nearOldest, initial: true) { _, near in
                guard near else { return }
                Task {
                    await NextFrame.drawn()
                    if follow.nearOldest, !follow.prepending { showEarlier(size) }
                }
            }
            .onChange(of: follow.seeking) { if let target = follow.seeking { seek(target, size: size) } }
        }
        .environment(\.chatHighlight, highlight.id)
        .environment(\.chatTarget, follow.target?.id)
        .environment(\.chatJump, ChatJump(column: column) { follow.seek($0) })
        .onChange(of: pendingJump) {
            guard let target = pendingJump else { return }
            pendingJump = nil
            follow.jump(to: target)
        }
    }

    /// 刻度滑条让开的系统滚动条宽：Mac 窗口右缘的悬浮滚动条（手机上的滚动指示条由滑条自己让，见 `ChatScrubber.edge`）。
    #if os(macOS)
    private static var scrollerWidth: CGFloat { 16 }
    #else
    private static var scrollerWidth: CGFloat { 0 }
    #endif

    /// 先描圈、排开到那一条（离屏远的地方排的是空白，跳去的那条所在的段由内容钉成真的），排好了再跳。
    private func seek(_ target: ChatFollow.Target, size: CGSize) {
        if target.landing == .flash { highlight.flash(target.id) }
        if let index = ids.firstIndex(of: target.id) { show(from: min(index, ids.count - window(size))) }
        pendingJump = target
    }

    /// 在上面再排开一段，正在读的不动（`ChatFollow.willPrepend`）。都排开了就什么也不做。
    private func showEarlier(_ size: CGSize) {
        let first = ids.count - window(size)
        guard first > 0 else { return }
        let from = max(0, first - paging.step(size, first))
        follow.willPrepend()
        show(from: from)
    }

    private func show(from index: Int) {
        shown = ids.indices.contains(index) ? ids[index...] : nil
    }
}

/// 对话排开多少：打开时排开最近几条（`first`），每次往上再排开几条（`step`）。都给出可见区的尺寸与排到的那一条之前有几条
/// （打开时是全部条数，往上翻时是最早排着的那条的下标），返回从那里往上数的条数。
nonisolated struct ChatPaging {
    let first: (_ size: CGSize, _ above: Int) -> Int
    let step: (_ size: CGSize, _ above: Int) -> Int

    /// 固定条数（会话页：段的大小定的）。
    static func fixed(first: Int, step: Int) -> ChatPaging { ChatPaging(first: { _, _ in first }, step: { _, _ in step }) }
}

/// 对话此刻排开的范围（交给内容）：排着最近 `count` 条；再往上排开一次会多 `earlier` 条（没有更早的为 0），`showEarlier` 排开它们。
struct ChatWindow {
    let count: Int
    let earlier: Int
    let showEarlier: () -> Void
}
