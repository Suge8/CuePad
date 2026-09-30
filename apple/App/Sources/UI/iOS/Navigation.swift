#if os(iOS)
import Foundation
import Observation
import SwiftUI

/// iOS 的导航状态：标签、各标签的推入路径、随手记面板、iPad 的任务面板。
/// 数据不在这里，页面直接订阅 Store；共用的页面状态（提示、新建位置、当前项目）在 `Workspace`。
@MainActor @Observable
final class Navigation {
    enum Tab: Hashable {
        case projects, tasks, search
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
        case tasks
        case search
        case card(UUID)
    }

    /// 随手记面板要记入的位置。
    struct Capture: Identifiable {
        let id = UUID()
        /// nil 表示未归档。
        var project: UUID?
    }

    var layout: Layout = .tabs
    var tab: Tab = .projects
    var projectsPath: [Route] = []
    var tasksPath: [Route] = []
    var searchPath: [Route] = []
    var capture: Capture?
    /// 分栏：侧栏选中的页与其上推入的页（打开的卡片纸页盖在项目页上）。
    var splitRoot: Route = .today
    var splitPath: [Route] = []
    /// 分栏：右侧任务面板。
    var showsTasks = false

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

    /// 项目进了回收站：从所有路径里移除它的页面。
    func pop(_ project: UUID?) {
        guard let project else { return }
        let gone = Route.project(project)
        for path in [\Navigation.projectsPath, \.tasksPath, \.searchPath, \.splitPath] {
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
    func startCapture() {
        capture = Capture(project: captureProject)
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
