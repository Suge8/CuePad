import CueStore
import Foundation
import Observation

extension Workspace {
    var top: Route { mainRoute }

    var currentProject: UUID? {
        let routes = layout == .narrow ? path : [mainRoute]
        return routes.reversed().compactMap { route in
            if case .project(let id) = route { id } else { nil }
        }.first
    }

    /// 只表达导航可见性；前后台、窗口遮挡与人在不在由 ViewerKeeper 处理。
    var shownSessions: [ViewerKeeper.Page] {
        let sessions: [SessionRoute]
        switch navigation {
        case .narrow(let state):
            if case .session(let route)? = state.path.last { sessions = [route] } else { sessions = [] }
        case .wide(let state):
            let main: SessionRoute? = if case .session(let route) = state.main, !state.home { route } else { nil }
            sessions = [main, state.home ? nil : state.beside].compactMap(\.self)
        }
        return sessions.map { ViewerKeeper.Page(id: $0.id, sessionID: $0.sessionID) }
    }

    /// 外部导航：窄屏会话推入，其余重选；宽屏会话与其余去处都换主区，Cue 在右边露出来（`showCue`）。
    func show(_ route: Route) {
        openTask = nil
        switch layout {
        case .narrow: showNarrow(route)
        case .wide: selectWide(route)
        }
    }

    /// 明确重选：窄屏回根并打开侧栏或目标页；宽屏同 show。
    func select(_ route: Route) {
        openTask = nil
        switch layout {
        case .narrow: selectNarrow(route)
        case .wide: selectWide(route)
        }
    }

    /// 页面内继续前往：窄屏压栈，宽屏替换所属栏。
    func push(_ route: Route) {
        switch layout {
        case .narrow: pushNarrow(route)
        case .wide: selectWide(route)
        }
    }

    /// 看着的东西没了（删了、进了回收站、文件不在了；本机删的和别处删的同一条路）：窄屏把它连同上面的页截出栈，
    /// 宽屏关掉盖着它的那一层，或主区回到浏览落点（Cue 铺满时只换下面留着的那一页，不把人从 Cue 拉走）。
    func leave(_ route: Route) {
        switch route {
        case .card(let id): close(.card(id))
        case .libraryFile(let file): close(.library(file))
        default: break
        }
        switch navigation {
        case .narrow(var state):
            guard let index = state.path.firstIndex(of: route) else { return }
            state.path = Array(state.path[..<index])
            navigation = .narrow(state)
        case .wide(var state):
            guard case .page(route) = state.main else { return }
            if state.home {
                state.main = .browse
                navigation = .wide(state)
            } else {
                selectWide(browseRoute)
            }
        }
    }

    func back() {
        switch layout {
        case .narrow: if !path.isEmpty { path.removeLast() }
        case .wide: if overlay != nil { overlay = nil } else { closeColumn(.main) }
        }
    }

    func showProgress(of project: UUID) {
        projectScope = project
        selectPane(.progress)
    }

    func open(_ target: CueWakeHeader.Target) {
        switch target {
        case .session(let id, let sessionID): openSession(id, sessionID: sessionID)
        case .task(let id): openTask(id: id)
        case .schedules: cue.showsSchedules = true
        }
    }

    func open(_ card: Card) {
        if card.isTask { return openTask(card) }
        openTask = nil
        showEditor(card.id)
    }

    /// 打开一个会话页（`sessionID` 是 Pi 的会话 id，只有记录 id 的入口不带）。去之前当场读好这一页（`sessionRoute`）：
    /// 读的是只读连接、只要几毫秒，推入的第一帧就有标题与对话，也不会被晚到的读取结果拉回已经离开的地方。读不到要去的会话时不去。
    /// 宽屏开在主区：默认替换左半（`main`），⌘ 点的开在右半并排（`beside`）。
    func openSession(_ id: UUID, sessionID: String? = nil, in column: Column = .main) {
        guard let route = sessionRoute(id, sessionID: sessionID) else { return }
        openTask = nil
        switch layout {
        case .narrow: showNarrow(route)
        case .wide:
            if case .session(let session) = route { openWideSession(session, in: column) }
        }
    }

    func go(to link: Route) {
        notice = nil
        guard case .session(let route) = link else { return show(link) }
        openSession(route.id, sessionID: route.sessionID)
    }

    func follow(_ next: TaskNext) {
        switch next {
        case .agent(_, let session): openSession(session.id, sessionID: session.sessionID)
        case .start(let leaf): handOff(leaf)
        }
    }

    /// ⌘1–9：打开侧栏里此刻的第 number 个项目。快捷键只绑数字，按下的那一刻才按项目目录当前的顺序取：
    /// 顺序随最近的进展与置顶变化，绑在某个项目上会在顺序变了之后打开错的。没有那么多个项目时什么也不做。
    func showProject(number: Int) {
        guard let projects = catalog?.projects, projects.indices.contains(number - 1) else { return }
        show(.project(projects[number - 1].id))
    }

    func newCard() {
        let project = currentProject ?? Project.defaultID
        attempt { self.open(try await self.createCard(in: project)) }
    }

    func speakToCue() {
        show(.cue)
        cueFocusPending = true
    }

    func open(_ link: DeepLink) {
        switch link {
        case .speak: speakToCue()
        // 链接里的项目可能已经不在了：落到项目列表，不停在一页空的上
        case .project(let id): if let catalog, catalog.project(id) == nil { show(.shelf) } else { show(.project(id)) }
        case .cue: show(.cue)
        case .session(let id): openSession(id)
        case .remoteBound(let device, let error, let nonce): Task { await remoteBound(device: device, error: error, nonce: nonce) }
        case .remoteFailed(let host, let reason): remoteFailed(host: host, reason: reason)
        case .card(let id):
            let store = services.store
            attempt { if let card = try await store.card(id) { self.open(card) } }
        }
    }

    /// iPad 开着几个窗口时谁先取到谁打开。
    func openLinks() async {
        for await _ in Observations({ self.services.pendingDeepLink }) {
            if let link = services.consumeDeepLink() { open(link) }
        }
    }
}

struct ProjectFormRequest: Identifiable {
    let id = UUID()
    var project: Project?
}

enum LibraryPane: Int, CaseIterable, Comparable {
    case rules, skills

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .rules: "规则"
        case .skills: "技能"
        }
    }

    var icon: Icon {
        switch self {
        case .rules: .instruction
        case .skills: .skill
        }
    }
}
