import CueStore
import Foundation
import Observation

/// 共用入口只分派布局；窄屏与宽屏的去处规则分别在 Workspace+Narrow、Workspace+Wide。
extension Workspace {
    /// 窄屏栈顶，宽屏主区；宽屏会话可见性读 shownSessions，不用 top 推测右栏。
    var top: Route { mainRoute }

    var currentProject: UUID? {
        let routes = layout == .narrow ? path : [mainRoute]
        return routes.reversed().compactMap { route in
            if case .project(let id) = route { id } else { nil }
        }.first
    }

    /// 一个窗口可见的会话，按左、右排列且不重复；窄屏只有侧栏、没有推入页时没有可见会话。
    /// 只表达导航可见性；前后台、窗口遮挡与人在不在由 ViewerKeeper 处理。
    var shownSessions: [ViewerKeeper.Page] {
        let sessions: [SessionRoute]
        switch navigation {
        case .narrow(let state):
            if case .session(let route)? = state.path.last { sessions = [route] } else { sessions = [] }
        case .wide(let state):
            let main: SessionRoute? = if case .session(let route) = state.main { route } else { nil }
            sessions = [main, state.side].compactMap(\.self)
        }
        return sessions.map { ViewerKeeper.Page(id: $0.id, sessionID: $0.sessionID) }
    }

    /// 外部导航：窄屏会话推入，其余重选；宽屏会话默认右栏、Cue 回右栏、其余换主区。
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

    func back() {
        switch layout {
        case .narrow: if !path.isEmpty { path.removeLast() }
        case .wide: closeColumn(.main)
        }
    }

    /// 去进展页的会话段（原会话页的去向都是这里："看这个项目的会话"、⌥⌘N）。
    func showSessions() {
        progressPane = .sessions
        show(.progress)
    }

    /// 去看待回复的会话：只有一个直接进那个会话；几个去进展页、停在你上次看的那一段——看板的等你列（拍板在前），
    /// 或会话段（排在等你确认之后、其余之前，`PiShown.rank`），它们亮一下（`spotlight`）。入口数的是全部项目，项目范围放开，一个不漏。
    func openReplies(_ replies: [PiSessionState]) {
        guard !replies.isEmpty else { return }
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
    func openSession(_ id: UUID, sessionID: String? = nil, in column: Column = .side) {
        guard let route = sessionRoute(id, sessionID: sessionID) else { return }
        openTask = nil
        switch layout {
        case .narrow: showNarrow(route)
        case .wide:
            if case .session(let session) = route { openWideSession(session, in: column) }
        }
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
