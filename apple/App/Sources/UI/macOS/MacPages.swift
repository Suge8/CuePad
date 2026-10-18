#if os(macOS)
import SwiftUI

/// 主窗口内容区挂着哪些页、侧栏开合（Mac）。当前页本身在 `Workspace.page`，这里只管"去过的页留着"。
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

    /// 侧栏开合一步到位：只改可见性，不包动画（分栏动画约 0.3 秒里每帧整窗重排、重算鼠标跟踪区，掉帧十几次）。
    func toggleSidebar() {
        sidebar = sidebar == .detailOnly ? .all : .detailOnly
    }

    /// 从 `left` 切到 `page`。
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

    /// 进了回收站或删掉的项目不再留着它的页。
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
