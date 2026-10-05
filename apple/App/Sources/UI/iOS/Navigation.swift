#if os(iOS)
import CueStore
import CueSync
import Foundation
import Observation
import SwiftUI

/// iOS 的导航状态：标签、各标签的推入路径、随手记、发到 Mac 与项目表单、iPad 的右侧面板。
/// 数据不在这里，页面直接订阅 Store；共用的页面状态（提示、当前项目）在 `Workspace`。
@MainActor @Observable
final class Navigation {
    enum Tab: Hashable {
        case projects, tasks, activity
    }

    /// iPhone（及窄窗口 iPad）用标签栏；宽 iPad 用分栏。
    enum Layout {
        case tabs, split
    }

    /// 可推入的页面。
    enum Route: Hashable {
        /// 项目书架（iPhone 项目标签的根；iPad 侧栏的"项目"）。
        case shelf
        case project(UUID)
        case inbox
        case today
        case trash
        case settings
        case conflicts
        case activity
        /// 一个项目的全部 Pi 会话（同 Pi 页，只列这个项目的）。
        case projectSessions(UUID)
        case search
        case card(UUID)
        /// 一个 Pi 会话的近况与回复（`PiSessionState.id`）。
        case session(UUID)

        var isCard: Bool { if case .card = self { true } else { false } }
    }

    /// 随手记面板：记入的位置与打开时先做什么。
    struct Capture: Identifiable {
        enum Start { case text, camera, photos }
        let id = UUID()
        /// nil 表示未归档。
        var project: UUID?
        var start: Start = .text
    }

    /// 要发到 Mac 的一张卡或一条任务（存储格式，变量已填）：先选会话，再在会话页里选方式发出。
    struct Outbox: Identifiable {
        let id = UUID()
        var content: String
        var card: UUID?
        var task: UUID?
        /// 卡片或任务所在项目：选会话时它的会话排在前面。
        var project: UUID?
    }

    /// 新建（`project` 为 nil）或编辑项目的表单；书架、侧栏与项目页的入口都经这里，在根视图弹出。
    struct ProjectForm: Identifiable {
        let id = UUID()
        var project: Project?
    }

    /// 新会话面板；`launched` 是已经发出的那一次（再打开时接着看它的进度）。
    struct NewSession: Identifiable {
        struct Launched: Equatable, Sendable {
            var request: UUID
            var token: String
        }

        let id = UUID()
        var launched: Launched?
    }

    /// 宽 iPad 右侧面板。
    enum Panel: Hashable { case tasks, activity }

    var layout: Layout = .tabs
    var tab: Tab = .projects
    var projectsPath: [Route] = []
    var tasksPath: [Route] = []
    var activityPath: [Route] = []
    /// 打开随手记的请求：页面底部有随手记时由它接住（见 `captureBars`），否则弹出随手记面板。
    var capture: Capture?
    /// 屏幕上页面底部随手记的个数。
    var captureBars = 0
    var outbox: Outbox?
    var projectForm: ProjectForm?
    var newSession: NewSession?
    /// 卡片纸页在屏幕上（推入途中起、返回开始止）：iPhone 此时隐藏标签栏，纸页独占底部。
    var showsCardPage = false
    /// 分栏：侧栏选中的页与其上推入的页（打开的卡片纸页盖在项目页上）。
    var splitRoot: Route = .shelf
    var splitPath: [Route] = []
    var sidebar: NavigationSplitViewVisibility = .automatic
    /// 分栏：右侧面板；nil 为收起。
    var panel: Panel?
    /// 带进会话页回复框的内容（卡片、任务、重发的记录），会话页出现时取走。
    private var replyDrafts: [UUID: Outbox] = [:]

    /// 随手记记入的位置：正在看的项目页（含其上打开的卡），否则未归档。
    var captureProject: UUID? {
        let visible: [Route] = switch layout {
        case .split: [splitRoot] + splitPath
        case .tabs: tab == .projects ? projectsPath : []
        }
        for route in visible.reversed() {
            if case .project(let id) = route { return id }
        }
        return nil
    }

    /// 在当前位置推入一页。
    func push(_ route: Route) {
        switch (layout, tab) {
        case (.split, _): splitPath.append(route)
        case (.tabs, .projects): projectsPath.append(route)
        case (.tabs, .tasks): tasksPath.append(route)
        case (.tabs, .activity): activityPath.append(route)
        }
    }

    func open(card id: UUID) {
        push(.card(id))
    }

    /// 分栏：侧栏选中一页，清掉其上推入的页。
    func select(_ route: Route) {
        splitRoot = route
        splitPath = []
    }

    /// 分栏：进入搜索前所在的页（含其上推入的页），退出搜索时回到这里。
    private var beforeSearch: (root: Route, path: [Route])?

    /// 每次 ⌘K（或点侧栏的搜索）加一：搜索页据此聚焦搜索框并全选已有文字，已在搜索页时同样生效。
    private(set) var searchFocusRequests = 0
    /// 标签栏布局下 ⌘K 要聚焦哪一页的下拉搜索（书架或某个项目页）；那一页聚焦后清掉。
    var pendingPageSearch: Route?

    /// 标签栏布局的 ⌘K：正看着书架或项目页就聚焦它的下拉搜索，其他页面回到书架再聚焦。
    func searchCurrentPage() {
        let top = tab == .projects ? projectsPath.last ?? .shelf : nil
        switch top {
        case .shelf, .project, .inbox:
            pendingPageSearch = top
        default:
            tab = .projects
            projectsPath = []
            pendingPageSearch = .shelf
        }
    }

    func openSearch() {
        searchFocusRequests += 1
        guard splitRoot != .search else { return }
        beforeSearch = (splitRoot, splitPath)
        select(.search)
    }

    /// 退出搜索，回到进入前的页；没有记录时回到书架。
    func closeSearch() {
        guard splitRoot == .search else { return }
        let back = beforeSearch ?? (.shelf, [])
        beforeSearch = nil
        splitRoot = back.root
        splitPath = back.path
    }

    func toggle(_ panel: Panel) {
        self.panel = self.panel == panel ? nil : panel
    }

    /// 项目进了回收站：从所有路径里移除它的页面。
    func pop(_ project: UUID?) {
        guard let project else { return }
        let gone = Route.project(project)
        for path in [\Navigation.projectsPath, \.tasksPath, \.activityPath, \.splitPath] {
            if let index = self[keyPath: path].firstIndex(of: gone) { self[keyPath: path].removeSubrange(index...) }
        }
        if splitRoot == gone { select(.shelf) }
    }

    /// 小组件与分享扩展的链接：随手记、项目、卡片。
    func open(_ link: DeepLink, workspace: Workspace) {
        switch link {
        case .capture(let project):
            capture = Capture(project: project)
        case .project(let id):
            workspace.show(.project(id))
            if layout == .split { select(.project(id)) } else { tab = .projects; projectsPath = [.project(id)] }
        case .card(let id):
            if layout == .tabs { tab = .projects }
            push(.card(id))
        }
    }

    /// 点开的 Pi 通知：直接打开该会话的近况（iPhone 在 Pi 标签里，iPad 推入详情栏）。
    func open(alert tap: PiAlertTap?) {
        guard let tap else { return }
        switch layout {
        case .tabs:
            tab = .activity
            activityPath = [.session(tap.sessionState)]
        case .split:
            if splitPath.last != .session(tap.sessionState) { splitPath.append(.session(tap.sessionState)) }
        }
    }

    /// 在当前位置推入一个会话的近况页；`draft` 预填进它的回复框（发到 Mac 的卡片或任务、要重发的内容）。
    func openSession(_ id: UUID, draft: Outbox? = nil) {
        outbox = nil
        if let draft { replyDrafts[id] = draft }
        push(.session(id))
    }

    /// 会话页出现时取走给它的预填内容。
    func takeDraft(for session: UUID) -> Outbox? {
        replyDrafts.removeValue(forKey: session)
    }

    /// 打开随手记，记入当前位置。
    func startCapture(_ start: Capture.Start = .text) {
        capture = Capture(project: captureProject, start: start)
    }

    /// 打开未归档（iPhone 推入项目标签，iPad 选中侧栏）。
    func showInbox() {
        if layout == .split { select(.inbox) } else { tab = .projects; projectsPath = [.inbox] }
    }

    /// 打开项目页（iPhone 推入项目标签，iPad 选中侧栏）。
    func show(project id: UUID, workspace: Workspace) {
        workspace.show(.project(id))
        if layout == .split { select(.project(id)) } else { tab = .projects; projectsPath = [.project(id)] }
    }
}

/// 卡片 ↔ 编辑纸页的缩放过渡共用的命名空间。
private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

extension View {
    /// 作为卡片缩放过渡的起点。
    @ViewBuilder func zoomSource(_ id: UUID, in namespace: Namespace.ID?) -> some View {
        if let namespace { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
}
#endif
