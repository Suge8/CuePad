import CueStore
import Foundation
import Observation

/// 去哪：两端同一套规则，入口（侧栏与底部那一排、⌘1–9、提示、深链、通知、组件里的"去会话"）都经这里；
/// 平台只给怎么摆（`Layout`）与呈现时顺带的事（`willSelect`、`showEditor`、`sessionRoute`，在各端的 `Workspace` 扩展里）。
extension Workspace {
    /// 去处怎么摆。
    enum Layout {
        /// Mac：内容区一次一页，没有历史、没有上一层，导航都在侧栏；会话页也是换页。
        case pages
        /// iPad 宽屏：侧栏选中的去处是根，会话页、卡片纸页推在它上面（返回回到原处）。
        case split
        /// 窄屏（iPhone 与窄窗口 iPad）：根只有底部那一排的四个（`Route.home`），其余去处推在它所属的那一页上。
        case dock

        /// 会话页推在当前页上、能返回。
        var keepsHistory: Bool { self != .pages }
    }

    /// 最上面那一页。
    var top: Route { path.last ?? root }

    /// 当前项目：正在看的项目页（含其上推入的页，如卡片纸页），否则没有。"在哪个项目"只有这一份：⌘N、任务页新建任务的默认落点都读它。
    var currentProject: UUID? {
        for route in ([root] + path).reversed() {
            if case .project(let id) = route { return id }
        }
        return nil
    }

    /// 屏幕上最上面那一页是会话页时是它（这个窗口开着哪个会话，`ViewerKeeper`）。
    var shownSession: ViewerKeeper.Page? {
        if case .session(let route) = top { ViewerKeeper.Page(id: route.id, sessionID: route.sessionID) } else { nil }
    }

    /// 去一页（提示、快捷键、深链与组件共用）：开着的任务气泡收起；有历史时会话页推在当前页上（已在看它就不再叠一页），其余经 `select`。
    func show(_ route: Route) {
        openTask = nil
        if case .session = route, layout.keepsHistory {
            if path.last != route { path.append(route) }
            return
        }
        select(route)
    }

    /// 换去处（侧栏与底部那一排点哪就是哪），清掉推入的页。窄屏上不在底部那一排的去处推在它所属的那一页上
    /// （项目、设置……推在书架上，Cue 的设置推在 Cue 页上）；不属于哪一页的（卡片纸页、会话页）推在当前页上。
    func select(_ route: Route) {
        let home = layout == .dock ? route.home : route
        let next = home ?? root
        willSelect(route, root: next)
        // 先换路径再换根：换了去处就没有可前进的页（`forward`），清掉推入的页不算返回
        path = home == route ? [] : [route]
        root = next
    }

    func push(_ route: Route) { path.append(route) }

    /// 去进展页的会话段（原会话页的去向都是这里：Cue 面板的"全部会话"、"看这个项目的会话"、⌥⌘N、提示条）。
    func showSessions() {
        progressPane = .sessions
        show(.progress)
    }

    /// 推回刚返回离开的那一页（`forward`）。会话页按此刻重读首帧（同 `openSession`）：离开后对话可能又长了。
    func goForward() {
        guard let forward else { return }
        guard case .session(let route) = forward else { return push(forward) }
        push(sessionRoute(route.id, sessionID: route.sessionID) ?? forward)
    }

    /// 打开一条灵感或任务：任务在气泡里看（`openTask`）；灵感（挂在任务下的资料也一样）进编辑页（`showEditor`）。
    func open(_ card: Card) {
        if card.isTask { return openTask(card) }
        openTask = nil
        showEditor(card.id)
    }

    /// 打开一个会话页（`sessionID` 是 Pi 的会话 id，只有记录 id 的入口不带）。去之前当场读好这一页（`sessionRoute`）：
    /// 读的是只读连接、只要几毫秒，推入的第一帧就有标题与对话，也不会被晚到的读取结果拉回已经离开的地方。读不到要去的会话时不去。
    func openSession(_ id: UUID, sessionID: String? = nil) {
        if let route = sessionRoute(id, sessionID: sessionID) { show(route) }
    }

    /// 点提示条去它说的地方（两端的提示共用）：会话经 `openSession`（同其他打开会话的入口先读好这一页），其余经 `show`。
    func go(to link: Route) {
        notice = nil
        guard case .session(let route) = link else { return show(link) }
        openSession(route.id, sessionID: route.sessionID)
    }

    /// 去"下一步"：打开会话，或把任务的正文交给 Agent（`handOff`）。
    func follow(_ next: TaskNext) {
        switch next {
        case .agent(_, let session): openSession(session.id, sessionID: session.sessionID)
        case .start(let leaf): handOff(leaf)
        }
    }

    /// ⌘1–9：打开侧栏里此刻的第 number 个项目。快捷键只绑数字，按下的那一刻才按项目目录当前的顺序取：
    /// 顺序随最近活动与置顶变化，绑在某个项目上会在顺序变了之后打开错的。没有那么多个项目时什么也不做。
    func showProject(number: Int) {
        guard let projects = catalog?.projects, projects.indices.contains(number - 1) else { return }
        show(.project(projects[number - 1].id))
    }

    /// ⌘N（Mac 的"文件 › 记一条灵感"）：在当前项目里新记一条灵感并打开它；不在项目里时记进默认项目。
    func newCard() {
        let project = currentProject ?? Project.defaultID
        attempt { self.open(try await self.createCard(in: project)) }
    }

    /// 去 Cue 页并让"对 Cue 说"拿到焦点（随手记小组件、手机的 ⌘⇧N）：要做事、随手记都从这里说。
    func speakToCue() {
        show(.cue)
        cueFocusPending = true
    }

    /// 小组件、分享扩展、实时活动的链接与点开的通知（`AppServices.pendingDeepLink`）：对 Cue 说、项目、卡片、Cue 页、会话。
    func open(_ link: DeepLink) {
        switch link {
        case .speak: speakToCue()
        case .project(let id): show(.project(id))
        case .cue: show(.cue)
        case .session(let id): openSession(id)
        case .card(let id):
            let store = services.store
            attempt { if let card = try await store.card(id) { self.open(card) } }
        }
    }

    /// 取走待打开的链接，直到所在任务取消（`follow`）：iPad 开着几个窗口时谁先取到谁打开。
    func openLinks() async {
        for await _ in Observations({ self.services.pendingDeepLink }) {
            if let link = services.consumeDeepLink() { open(link) }
        }
    }
}

/// 新建（`project` 为 nil）或编辑哪个项目的表单（`Workspace.projectForm`）。
struct ProjectFormRequest: Identifiable {
    let id = UUID()
    var project: Project?
}

/// 进展页的两段（`Workspace.progressPane`）：看板与会话。
enum ProgressPane: Hashable {
    case board, sessions
}

