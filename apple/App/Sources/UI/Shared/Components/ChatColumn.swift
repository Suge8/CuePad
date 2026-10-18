import SwiftUI

/// 对话页的对话区（会话页与 Cue 页、Mac 与 iPhone 同一个）：滚动区（`ChatScroll`）里只排最近几条（多少由 `paging` 按可见区的高定），
/// 离最早那头不到一屏时（往上翻、或排开的几条铺不满一屏）再排开一段。排开到哪按那一条记（`oldest`），不按条数：新的在下面长出来、
/// 读的范围丢掉了最早的几条（Cue 页只读最近 `CueThread.limit` 条）时，上面已经排着的不被挤掉——挤掉的话正在看的整段一下往上窜；右缘的刻度滑条（`ChatScrubber`）与内容里的 `chatJump` 跳到某一条，跳到后描一圈（`chatHighlight`）。
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
    /// 排开到的最早那一条；还没排（没有内容）为 nil。
    @State private var oldest: UUID?
    @State private var highlight = ChatHighlight()
    @State private var pendingJump: UUID?
    /// 这个对话区的身份（`ChatJump` 按它比较）。
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

    /// 排着几条：从记下的那一条到最新；还没记下，或它已不在读的范围里时，打开时的那么多（`paging.first`，按可见区的高 `height`）。
    private func window(_ height: CGFloat) -> Int {
        guard let oldest, let index = ids.firstIndex(of: oldest) else { return min(ids.count, paging.first(height, ids.count)) }
        return ids.count - index
    }

    /// 可见区的高在同一次排版里拿到（GeometryReader 先拿到自己的尺寸再排里面）：打开的第一帧就按它排开，不先排一帧再补。
    var body: some View {
        GeometryReader { proxy in
            let height = proxy.size.height, window = self.window(height), first = ids.count - window
            ChatScroll(followKey: followKey, readingWidth: readingWidth, inset: inset, follow: $follow, holding: holding) {
                content(ChatWindow(count: window, earlier: first > 0 ? paging.step(height, first) : 0) { showEarlier(height) })
            }
            .onChange(of: ids, initial: true) { if oldest.flatMap(ids.firstIndex(of:)) == nil { show(from: ids.count - self.window(height)) } }
            .onChange(of: follow.nearOldest, initial: true) { _, near in if near { showEarlier(height) } }
            .onChange(of: follow.seeking) { if let id = follow.seeking?.id { seek(id, height: height) } }
        }
        .environment(\.chatHighlight, highlight.id)
        .environment(\.chatJump, ChatJump(column: column) { follow.seek($0) })
        .overlay(alignment: .trailing) {
            if !marks.isEmpty {
                ChatScrubber(marks: marks, scrolling: follow.scrolling) { follow.seek($0) }
                    .padding(.trailing, Self.scrollerWidth)
            }
        }
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
    private func seek(_ id: UUID, height: CGFloat) {
        highlight.flash(id)
        if let index = ids.firstIndex(of: id) { show(from: min(index, ids.count - window(height))) }
        pendingJump = id
    }

    /// 在上面再排开一段，正在读的不动（`ChatFollow.willPrepend`）。都排开了就什么也不做。
    private func showEarlier(_ height: CGFloat) {
        let first = ids.count - window(height)
        guard first > 0 else { return }
        let from = max(0, first - paging.step(height, first))
        DebugHooks.chatShowsEarlier(from: from, of: ids.count)
        follow.willPrepend()
        show(from: from)
    }

    /// 从第 `index` 条排起（记下那一条）。
    private func show(from index: Int) {
        oldest = ids.indices.contains(index) ? ids[index] : nil
    }
}

/// 对话排开多少：打开时排开最近几条（`first`），每次往上再排开几条（`step`）。都给出可见区的高与排到的那一条之前有几条
/// （打开时是全部条数，往上翻时是最早排着的那条的下标），返回从那里往上数的条数。
nonisolated struct ChatPaging {
    let first: (_ height: CGFloat, _ above: Int) -> Int
    let step: (_ height: CGFloat, _ above: Int) -> Int

    /// 固定条数（会话页：段的大小定的）。
    static func fixed(first: Int, step: Int) -> ChatPaging { ChatPaging(first: { _, _ in first }, step: { _, _ in step }) }
}

/// 对话此刻排开的范围（交给内容）：排着最近 `count` 条；再往上排开一次会多 `earlier` 条（没有更早的为 0），`showEarlier` 排开它们。
struct ChatWindow {
    let count: Int
    let earlier: Int
    let showEarlier: () -> Void
}
