#if os(macOS)
import SwiftUI

/// 主窗口内容区挂着哪些页、侧栏开合（Mac）。当前页本身在 `Workspace.root`，这里只管"去过的页留着"。
@Observable
final class MacPages {
    var sidebar: NavigationSplitViewVisibility = .all

    /// 内容区挂着的页（`PageStack`）：去过的页留着，回访不再重建；至多 `keptPages` 个，满了换掉最久没看的。会话页不留（带着输入焦点与实时对话，挂着不看会抢键盘）。
    private(set) var kept: [Route] = []

    /// 刚离开的页：切页的那一帧它已经看不见，但"不在前台"（暂停订阅、停读实时状态）晚两帧才生效——页面重新求值要几十毫秒，不放在点击的回合里。
    private(set) var leaving: Route?

    @ObservationIgnored private var current: Route?
    @ObservationIgnored private var lastSeen: [Route: Int] = [:]
    @ObservationIgnored private var visits = 0
    @ObservationIgnored private var trimTask: Task<Void, Never>?
    static let keptPages = 4

    /// 开合侧栏的动画里详情区里的页摆在哪（`SidebarMotion`）：动画结束时的左缘与宽度；不在动时 nil。
    private(set) var detailHold: DetailHold?
    @ObservationIgnored private var detailFrame = CGRect.zero
    /// 侧栏开着、不在动时详情区的左缘：展开后详情区从哪起（侧栏这一栏的宽另有内边距，不能拿它算）。还没见过侧栏开着时为 nil。
    @ObservationIgnored private var openedMinX: CGFloat?
    @ObservationIgnored private var motions = 0
    @ObservationIgnored let slide = ColumnSlide()
    /// 页滑动时两边多铺的底色，不小于侧栏最宽的那一栏。
    static let slideOverscan: CGFloat = 400

    /// 开合侧栏：分栏照常动画，详情区里的页在动之前按终点排好，动画里只平移图层、左缘贴着侧栏的边走（`SidebarMotion`）。
    /// 跟着每帧的宽度重排时每帧主线程约 16ms、800ms 里掉帧十几次；这样每帧约 6ms。动画中途再按，按新的终点重新排一次。
    func toggleSidebar() {
        let opening = sidebar == .detailOnly
        let leading = opening ? openedMinX : 0
        detailHold = leading.map { DetailHold(leading: $0, width: detailFrame.maxX - $0) }
        slide.hold(detailHold)
        motions += 1
        let motion = motions
        withAnimation(Motion.snappy) {
            sidebar = opening ? .all : .detailOnly
        } completion: { [weak self] in
            guard let self, motion == motions else { return }
            detailHold = nil
            slide.hold(nil)
        }
    }

    /// 详情区这一栏的图层：动画里平移到侧栏这一帧的边，页按终点排好、左缘贴着侧栏走；不在动时复位。
    /// 侧栏的边就是详情区的左侧安全区，它与侧栏在同一次布局里变，平移跟着同一次提交上屏；按下开合的那一下就平移，页按终点排好的那一帧不会先跳过去。
    @MainActor
    final class ColumnSlide {
        weak var layer: CALayer?
        private var edge: CGFloat = 0
        private var leading: CGFloat?

        func follow(edge: CGFloat) {
            self.edge = edge
            apply()
        }

        func hold(_ hold: DetailHold?) {
            leading = hold?.leading
            apply()
        }

        private func apply() {
            guard let layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.setAffineTransform(CGAffineTransform(translationX: leading.map { edge - $0 } ?? 0, y: 0))
            CATransaction.commit()
        }
    }

    struct DetailHold: Equatable {
        var leading: CGFloat
        var width: CGFloat
    }

    /// 详情区在窗口里的位置（几何读数，`MainWindow` 写；不触发重算）。
    func detailMoved(to frame: CGRect) {
        detailFrame = frame
        if sidebar != .detailOnly, detailHold == nil { openedMinX = frame.minX }
    }

    func visit(from left: Route, to page: Route) {
        current = page
        keep(left)
        keep(page)
        guard left != page else { return }
        leaving = left
        Task { [weak self] in
            await NextFrame.wait()
            await NextFrame.wait()
            if self?.leaving == left { self?.leaving = nil }
        }
    }

    private func keep(_ page: Route) {
        if case .session = page { return }
        visits += 1
        lastSeen[page] = visits
        guard !kept.contains(page) else { return }
        kept.append(page)
        // 多出来的页不在这次点击里卸：卸一整页的视图树要几十毫秒，等切页的那一帧出去、安静下来再卸；连着去了很多页时先卸
        if kept.count > Self.keptPages + 2 { trim() } else { scheduleTrim() }
    }

    /// 启动后空闲时先挂上一页（`Prewarm`）：它先读一份数据把整页建好（`pagePrefetch`），第一次点开就是回访，
    /// 现建整页（Agent 页十几行会话要几十毫秒）不落在点击的回合里。不算去过，留着的页满了先换掉它。
    func premount(_ page: Route) {
        if !kept.contains(page) { kept.append(page) }
    }

    /// 先挂上、还没去过的页（`premount`）：去过的页都记着最后一次看它。
    func isPremounted(_ page: Route) -> Bool { lastSeen[page] == nil }

    func forget(projectsNotIn ids: Set<UUID>) {
        let gone = kept.filter { if case .project(let id) = $0 { !ids.contains(id) } else { false } }
        if !gone.isEmpty { kept.removeAll { gone.contains($0) } }
    }

    private func scheduleTrim() {
        trimTask?.cancel()
        trimTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.trim()
        }
    }

    /// 只留最近看过的 `keptPages` 页，当前页一定留着。
    private func trim() {
        let stale = kept.filter { $0 != current }.sorted { lastSeen[$0, default: 0] < lastSeen[$1, default: 0] }.prefix(max(0, kept.count - Self.keptPages))
        if !stale.isEmpty { kept.removeAll { stale.contains($0) } }
    }
}
#endif
