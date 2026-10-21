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

    /// 开合侧栏的动画里详情区里的页按终点排好的左缘（`SidebarMotion`，宽是从它到详情区的右缘）；不在动时 nil。
    /// 一变就把详情区这一栏的图层平移到侧栏此刻的边（`slide`）。
    private(set) var held: CGFloat? { didSet { slide() } }
    /// 侧栏开着、不在动时详情区的左缘：展开后详情区从哪起（侧栏这一栏的宽另有内边距，不能拿它算）。还没见过侧栏开着时为 nil。
    @ObservationIgnored private var openedMinX: CGFloat?
    /// 详情区这一栏的图层（`ColumnFinder`）与侧栏这一帧的边（详情区的左侧安全区）：平移量是边减 `held`。
    @ObservationIgnored weak var column: CALayer?
    @ObservationIgnored private var edge: CGFloat = 0
    @ObservationIgnored private var motions = 0
    /// 收起正在动时又按了展开：等收起动完再展开（`toggleSidebar`）。
    @ObservationIgnored private var reopen = false
    /// 页滑动时两边多铺的底色，不小于侧栏最宽的那一栏。
    static let slideOverscan: CGFloat = 400

    /// 开合侧栏：分栏照常动画，详情区里的页在动之前按终点排好，动画里只平移图层、左缘贴着侧栏的边走（`SidebarMotion`）。
    /// 跟着每帧的宽度重排时每帧主线程约 16ms、800ms 里掉帧十几次；这样每帧约 6ms。展开途中再按收起，按新的终点重新排一次、从当前位置收回。
    /// 收起途中再按展开不打断：分栏不支持这样反向，会先一步跳到收起、下一帧再不带动画地跳到展开（侧栏闪没一帧）；改成收起动完接着展开，再按一次就取消。
    func toggleSidebar() {
        let opening = sidebar == .detailOnly
        if opening, held != nil {
            reopen.toggle()
            return
        }
        held = opening ? openedMinX : 0
        motions += 1
        let motion = motions
        withAnimation(Motion.snappy, completionCriteria: .removed) {
            sidebar = opening ? .all : .detailOnly
        } completion: { [weak self] in
            guard let self, motion == motions else { return }
            held = nil
            if reopen {
                reopen = false
                toggleSidebar()
            }
        }
    }

    /// 侧栏这一帧的边（几何读数，`SidebarMotion` 写）。它与侧栏在同一次布局里变，平移跟着同一次提交上屏；
    /// 按下开合的那一下（`held` 变）就平移，页按终点排好的那一帧不会先跳过去。
    func follow(edge: CGFloat) {
        self.edge = edge
        slide()
    }

    /// 详情区在窗口里的左缘（几何读数，`MainWindow` 写；不触发重算）。
    func detailMoved(toMinX minX: CGFloat) {
        if sidebar != .detailOnly, held == nil { openedMinX = minX }
    }

    private func slide() {
        column?.setAffineTransform(CGAffineTransform(translationX: held.map { edge - $0 } ?? 0, y: 0))
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
