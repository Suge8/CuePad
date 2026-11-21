import Foundation

extension Workspace {
    /// NavigationLink 和系统返回直接写路径；书架的链接也要记下浏览分段与新记灵感默认进的项目（`remember`）。
    func setNarrowPath(_ next: [Route]) {
        guard layout == .narrow else { return }
        if let route = next.last { remember(route) }
        path = next
    }

    func showNarrow(_ route: Route) {
        if case .session = route { pushNarrow(route) } else { selectNarrow(route) }
    }

    func selectNarrow(_ route: Route) {
        remember(route)
        switch route {
        case .cue: navigation = .narrow(NarrowNavigation())
        case .shelf, .progress: navigation = .narrow(NarrowNavigation(sidebarOpen: true))
        case .project: navigation = .narrow(NarrowNavigation(path: [route], sidebarOpen: true))
        default: navigation = .narrow(NarrowNavigation(path: [route]))
        }
    }

    /// 推入页盖住 Cue 与侧栏；保留根的开合值，系统返回无需另存来源。
    func pushNarrow(_ route: Route) {
        switch route {
        case .cue, .shelf, .progress: return selectNarrow(route)
        default: break
        }
        guard case .narrow(var state) = navigation else { return }
        remember(route)
        if let index = state.path.firstIndex(of: route) {
            state.path = Array(state.path[...index])
        } else {
            state.path.append(route)
        }
        navigation = .narrow(state)
    }

    var ideaDock: IdeaDock? { if case .narrow(let state) = navigation { state.dock } else { nil } }
    var pickingDock: Bool { ideaDock.map { $0.session == nil } ?? false }

    /// 边聊边看：回到 Cue 页的会话条上挑一个会话，推入的下一个会话页就停着这条灵感（`IdeaDock`）。挑着时顶上那条提示一直在（`Notice.Tone.pick`）。
    /// 调用方先让编辑页把字落盘：停靠里的编辑器按库里的正文载入。
    func pickDock(_ card: UUID) {
        guard layout == .narrow else { return }
        navigation = .narrow(NarrowNavigation(dock: IdeaDock(card: card)))
        say("选一个会话", tone: .pick, action: NoticeAction(title: String(localized: "取消")) { $0.setDock(nil) })
    }

    func setDock(_ dock: IdeaDock?) {
        guard case .narrow(var state) = navigation else { return }
        state.dock = dock
        navigation = .narrow(state)
    }
}
