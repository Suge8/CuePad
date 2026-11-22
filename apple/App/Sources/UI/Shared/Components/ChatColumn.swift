import SwiftUI

struct ChatColumn<Content: View, Key: Equatable>: View {
    let followKey: Key
    let readingWidth: CGFloat
    let inset: CGFloat
    @Binding var follow: ChatFollow
    let marks: [ChatMark]
    let ids: [UUID]
    let paging: ChatPaging
    let holding: Bool
    let arrival: UUID?
    @ViewBuilder let content: (ChatWindow) -> Content
    /// 连后面的一起记：那一条自己掉出了读的范围（排开到了最早那头，来一句新的它就掉出去），从它后面还在的第一条排（`start`），不缩回一屏——缩回去内容一下矮了几屏，可见区落在内容外、整屏空白。
    /// 在同一次更新里就接上：等 `onChange` 改记已晚了一帧，那一帧缩回去又长回来，正在看的先被甩到最早那头再滑回来。
    @State private var shown: ArraySlice<UUID>?
    @State private var highlight = ChatHighlight()
    @State private var column = UUID()
    @State private var reading = ChatReading()

    init(
        followKey: Key, readingWidth: CGFloat, inset: CGFloat, follow: Binding<ChatFollow>, marks: [ChatMark], ids: [UUID],
        paging: ChatPaging, holding: Bool, arrival: UUID? = nil, @ViewBuilder content: @escaping (ChatWindow) -> Content
    ) {
        self.followKey = followKey
        self.readingWidth = readingWidth
        self.inset = inset
        _follow = follow
        self.marks = marks
        self.ids = ids
        self.paging = paging
        self.holding = holding
        self.arrival = arrival
        self.content = content
    }

    /// 记下时的可见区可能还不是最终的（iPhone 冷启动时第一次排版的窗口只有图标那么大），按那时记的条数排，可见区长大的那一帧上面就空着。
    private func window(_ size: CGSize) -> Int {
        let screen = min(ids.count, paging.first(size, ids.count))
        guard let start else { return screen }
        return max(ids.count - start, screen)
    }

    private var start: Int? {
        guard let shown, let first = shown.first else { return nil }
        if let index = ids.firstIndex(of: first) { return index }
        let present = Dictionary(ids.enumerated().map { ($1, $0) }) { earlier, _ in earlier }
        return shown.lazy.compactMap { present[$0] }.first
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size, window = self.window(size), first = ids.count - window
            let margin = ChatLayout.margin(size.width, readingWidth: readingWidth, inset: inset)
            ChatScroll(followKey: followKey, readingWidth: readingWidth, inset: inset, follow: $follow, holding: holding, arrival: arrival) {
                content(ChatWindow(count: window, earlier: first > 0 ? paging.step(size, first) : 0) { showEarlier(size) })
                    .environment(\.chatMargin, margin)
            }
            .environment(\.chatReading, reading)
            .overlay(alignment: .trailing) {
                if !marks.isEmpty {
                    ChatIndex(marks: marks, ids: ids, reading: reading, scrolling: follow.scrolling, crowded: margin < ChatIndex.room) { follow.seek($0) }
                }
            }
            .onChange(of: ids, initial: true) {
                let index = start ?? ids.count - self.window(size)
                if shown?.first != (ids.indices.contains(index) ? ids[index] : nil) { show(from: index) }
            }
            .onChange(of: follow.wantsEarlier, initial: true) { _, wants in
                guard wants else { return }
                Task {
                    await NextFrame.drawn()
                    if follow.wantsEarlier { showEarlier(size) }
                }
            }
            .onChange(of: follow.seeking) { if let target = follow.seeking { seek(target, size: size) } }
        }
        .environment(\.chatHighlight, highlight.id)
        .environment(\.chatTarget, follow.target?.id)
        .environment(\.chatJump, ChatJump(column: column) { follow.seek($0) })
        .environment(\.chatStay, ChatStay(column: column) { follow.stay($0, $1) })
    }

    private func seek(_ target: ChatFollow.Target, size: CGSize) {
        if target.landing == .flash { highlight.flash(target.id) }
        if let index = ids.firstIndex(of: target.id) { show(from: max(0, min(index - paging.step(size, index), ids.count - window(size)))) }
        follow.jump(to: target)
    }

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

nonisolated struct ChatPaging {
    let first: (_ size: CGSize, _ above: Int) -> Int
    let step: (_ size: CGSize, _ above: Int) -> Int

    static func fixed(first: Int, step: Int) -> ChatPaging { ChatPaging(first: { _, _ in first }, step: { _, _ in step }) }
}

struct ChatWindow {
    let count: Int
    let earlier: Int
    let showEarlier: () -> Void
}
