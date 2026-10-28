import CueStore
import Foundation
import Observation

/// 去哪：两端同一套规则，入口（侧栏与底部那一排、⌘1–9、提示、深链、通知、看板的卡、Cue 页的旁注与待回复提示、组件里的"去会话"）都经这里；
/// 平台只给怎么摆（`Layout`）与呈现时顺带的事（`willSelect`、`showEditor`、`sessionRoute`，在各端的 `Workspace` 扩展里）。
extension Workspace {
    /// 去处怎么摆。
    enum Layout {
        /// Mac：内容区一次一页，没有历史、没有上一层，导航都在侧栏；会话页也是换页。
        case pages
        /// iPad 宽屏：侧栏选中的去处是根，会话页、卡片纸页推在它上面（返回回到原处）。
        case split
        /// 窄屏（iPhone 与窄窗口 iPad）：根只有底部那一排的三个 tab（`Dock.tabs`，`Route.home`），各有自己的导航栈，其余去处推在它所属的那个 tab 上。
        case dock

        /// 会话页推在当前页上、能返回。
        var keepsHistory: Bool { self != .pages }
    }

    /// 最上面那一页。
    var top: Route { path.last ?? root }

    /// 当前项目：正在看的项目页（含其上推入的页，如卡片纸页），否则没有。"在哪个项目"只有这一份：⌘N、进展页新建任务的默认落点都读它。
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

    /// 去这一页（侧栏点哪就是哪、快捷键、深链），清掉它那一栈推入的页。窄屏上不是 tab 的去处推在它所属的那个 tab 上
    /// （项目、设置……推在书架上），别的 tab 的栈不动；不属于哪一页的（卡片纸页、会话页）推在当前 tab 上。点底部那一排只换 tab，不经这里（`tap`）。
    func select(_ route: Route) {
        let next = (layout == .dock ? route.home : route) ?? root
        willSelect(route, root: next)
        if layout != .dock { clearStacks() }
        self[stack: next] = next == route ? [] : [route]
        root = next
    }

    func push(_ route: Route) { path.append(route) }

    /// 去进展页的会话段（原会话页的去向都是这里："看这个项目的会话"、⌥⌘N）。
    func showSessions() {
        progressPane = .sessions
        show(.progress)
    }

    /// 去看待回复的会话（Cue 页的待回复提示）：只有一个直接进那个会话；几个去进展页、停在你上次看的那一段——看板的等你列（拍板在前），
    /// 或会话段（排在等你确认之后、其余之前，`PiShown.rank`），它们亮一下（`spotlight`）。提示数的是全部项目，项目范围放开，一个不漏。
    func openReplies(_ replies: [PiSessionState]) {
        if replies.count == 1 { return openSession(replies[0].id, sessionID: replies[0].sessionID) }
        projectScope = nil
        spotlight = Spotlight(replies.map(\.sessionID))
        show(.progress)
    }

    /// 去 Cue 页一行旁注提到的那一处（醒来那几行、一轮的经过）：会话、任务（从点的地方长出气泡）或定时。
    func open(_ target: CueWakeHeader.Target) {
        switch target {
        case .session(let id, let sessionID): openSession(id, sessionID: sessionID)
        case .task(let id): openTask(id: id)
        case .schedules: cue.showsSchedules = true
        }
    }

    /// 打开一条灵感或任务：任务在气泡里看（`openTask`）；灵感（挂在任务下的也一样）进编辑页（`showEditor`）。
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
    /// 顺序随最近的进展与置顶变化，绑在某个项目上会在顺序变了之后打开错的。没有那么多个项目时什么也不做。
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
enum ProgressPane: String, Hashable {
    case board, sessions
}

/// 技能与规则页的两段（`Workspace.libraryPane`），先后即分段里的左右。
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
