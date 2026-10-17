import SwiftUI

/// 对话页的对话区（会话页与 Cue 页、Mac 与 iPhone 同一个）：滚动区（`ChatScroll`）里只排最近 `window` 条，离最早那头不到一屏时
/// （往上翻、或排开的几条铺不满一屏）再排开一段（`ChatPaging`）。排开到哪按那一条记（`oldest`），不按条数：新的在下面长出来、
/// 读的范围丢掉了最早的几条（Cue 页只读最近 `CueThread.limit` 条）时，上面已经排着的不被挤掉——挤掉的话正在看的整段一下往上窜；右缘的刻度滑条（`ChatScrubber`）与内容里的 `chatJump` 跳到某一条，跳到后描一圈（`chatHighlight`）。
/// 先描圈、排开（那条所在的地方排成真的），下一次更新再跳：同一次更新里跳，目标还不在滚动区里。
/// 内容只管按 `window` 排哪几条、它们长什么样；排开、跳转、描圈与刻度都在这里。`holding`：本机正在和 iCloud 对，见 `ChatScroll`。
struct ChatColumn<Content: View, Key: Equatable>: View {
    let followKey: Key
    let readingWidth: CGFloat
    let inset: CGFloat
    @Binding var follow: ChatFollow
    /// 刻度：你说的话与换上下文的地方（先后）。
    let marks: [ChatMark]
    /// 对话里的各条，从最早那条起；`content` 排的是它的最后 `window` 条。
    let ids: [UUID]
    let paging: ChatPaging
    let holding: Bool
    @ViewBuilder let content: (_ window: Int, _ showEarlier: @escaping () -> Void) -> Content
    /// 排开到的最早那一条；还没排（没有内容）为 nil。
    @State private var oldest: UUID?
    @State private var highlight = ChatHighlight()
    @State private var pendingJump: UUID?

    init(
        followKey: Key, readingWidth: CGFloat, inset: CGFloat, follow: Binding<ChatFollow>, marks: [ChatMark], ids: [UUID],
        paging: ChatPaging, holding: Bool,
        @ViewBuilder content: @escaping (_ window: Int, _ showEarlier: @escaping () -> Void) -> Content
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

    /// 排着几条：从记下的那一条到最新；还没记下，或它已不在读的范围里时，最初的那一段（`ChatPaging.initial`）。
    private var window: Int {
        guard let oldest, let index = ids.firstIndex(of: oldest) else { return ids.count - paging.initial(ids.count) }
        return ids.count - index
    }

    var body: some View {
        ChatScroll(followKey: followKey, readingWidth: readingWidth, inset: inset, follow: $follow, holding: holding) {
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
        .onChange(of: ids, initial: true) { if oldest.flatMap(ids.firstIndex(of:)) == nil { show(from: ids.count - window) } }
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
        if let index = ids.firstIndex(of: id) { show(from: min(index, ids.count - window)) }
        pendingJump = id
    }

    /// 在上面再排开一段，正在读的不动（`ChatFollow.willPrepend`）。都排开了就什么也不做。
    private func showEarlier() {
        guard window < ids.count else { return }
        let from = paging.earlier(ids.count - window)
        DebugHooks.chatShowsEarlier(from: from, of: ids.count)
        follow.willPrepend()
        show(from: from)
    }

    /// 从第 `index` 条排起（记下那一条）。
    private func show(from index: Int) {
        oldest = ids.indices.contains(index) ? ids[index] : nil
    }
}

/// 对话一开始排开最近的一段、往上翻快到头时再排开一段：按条数（会话页，一条是一轮），或按估计的高（Cue 页，一格高矮悬殊）。
nonisolated enum ChatPaging: Equatable {
    case count(first: Int, step: Int)
    /// 每段排到估计的高合起来够 `span`：`extents` 是每一条估计的高（与 `ids` 同序），宜低不宜高——估低了多排几条，
    /// 估高了排开的铺不满，打开时上面先空一帧。
    case height(_ extents: [CGFloat], span: CGFloat)

    /// 共 `count` 条时最初从第几条排起。
    func initial(_ count: Int) -> Int {
        switch self {
        case .count(let first, _): max(0, count - first)
        case .height: earlier(count)
        }
    }

    /// 已从第 `end` 条排起时，再排开一段从第几条起。
    func earlier(_ end: Int) -> Int {
        switch self {
        case .count(_, let step): return max(0, end - step)
        case .height(let extents, let span):
            var start = min(end, extents.count), sum: CGFloat = 0
            while start > 0, sum < span {
                start -= 1
                sum += extents[start]
            }
            return start
        }
    }
}
