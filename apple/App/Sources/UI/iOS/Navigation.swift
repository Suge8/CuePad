#if os(iOS)
import Foundation
import Observation
import SwiftUI

/// iOS 的导航状态：标签、各标签的推入路径、随手记与发到 Mac 面板、iPad 的右侧面板。
/// 数据不在这里，页面直接订阅 Store；共用的页面状态（提示、当前项目）在 `Workspace`。
@MainActor @Observable
final class Navigation {
    enum Tab: Hashable {
        case projects, tasks, activity, search
    }

    /// iPhone（及窄窗口 iPad）用标签栏；宽 iPad 用分栏。
    enum Layout {
        case tabs, split
    }

    /// 可推入的页面。
    enum Route: Hashable {
        case project(UUID)
        case inbox
        case today
        case trash
        case settings
        case conflicts
        case activity
        case search
        case card(UUID)
    }

    /// 随手记面板：记入的位置与打开时先做什么。
    struct Capture: Identifiable {
        enum Start { case text, camera, photos }
        let id = UUID()
        /// nil 表示未归档。
        var project: UUID?
        var start: Start = .text
    }

    /// 发到 Mac 面板要发的内容（存储格式，变量已填、编号已排）。
    struct Outbox: Identifiable {
        let id = UUID()
        var content: String
        var card: UUID?
        var task: UUID?
        /// 预选的 Pi 会话（重发时）。
        var session: String?
        /// 预选会话所属项目（卡片所在项目），没有指定会话时优先选它的会话。
        var project: UUID?
    }

    /// 宽 iPad 右侧面板。
    enum Panel: Hashable { case tasks, activity }

    var layout: Layout = .tabs
    var tab: Tab = .projects
    var projectsPath: [Route] = []
    var tasksPath: [Route] = []
    var activityPath: [Route] = []
    var searchPath: [Route] = []
    var capture: Capture?
    var outbox: Outbox?
    /// 分栏：侧栏选中的页与其上推入的页（打开的卡片纸页盖在项目页上）。
    var splitRoot: Route = .today
    var splitPath: [Route] = []
    var sidebar: NavigationSplitViewVisibility = .automatic
    /// 分栏：右侧面板；nil 为收起。
    var panel: Panel?

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

    /// 标签栏布局下，当前标签最上面是打开的卡片。
    var isEditingCard: Bool {
        let path = switch tab {
        case .projects: projectsPath
        case .tasks: tasksPath
        case .activity: activityPath
        case .search: searchPath
        }
        if case .card = path.last { return true }
        return false
    }

    /// 在当前位置推入一页。
    func push(_ route: Route) {
        switch (layout, tab) {
        case (.split, _): splitPath.append(route)
        case (.tabs, .projects): projectsPath.append(route)
        case (.tabs, .tasks): tasksPath.append(route)
        case (.tabs, .activity): activityPath.append(route)
        case (.tabs, .search): searchPath.append(route)
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

    func toggle(_ panel: Panel) {
        self.panel = self.panel == panel ? nil : panel
    }

    /// 项目进了回收站：从所有路径里移除它的页面。
    func pop(_ project: UUID?) {
        guard let project else { return }
        let gone = Route.project(project)
        for path in [\Navigation.projectsPath, \.tasksPath, \.activityPath, \.searchPath, \.splitPath] {
            if let index = self[keyPath: path].firstIndex(of: gone) { self[keyPath: path].removeSubrange(index...) }
        }
        if splitRoot == gone { select(.today) }
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

    /// 打开随手记，记入当前位置。
    func startCapture(_ start: Capture.Start = .text) {
        capture = Capture(project: captureProject, start: start)
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
