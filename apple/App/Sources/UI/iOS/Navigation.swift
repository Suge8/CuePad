#if os(iOS)
import CueStore
import CueSync
import Foundation
import Observation
import SwiftUI

/// iOS 的导航状态：标签（Cue / Agent / 灵感）、各标签的推入路径、随手记、发到 Mac 与项目表单、iPad 的右侧 Agent 面板。
/// 数据不在这里，页面直接订阅 Store；共用的页面状态（提示、项目目录）在 `Workspace`。当前项目只从路径推出（`currentProject`）。
@Observable
final class Navigation {
    /// 底部从左到右的顺序就是声明的顺序；打开 App 先到 Cue。
    enum Tab: Hashable, CaseIterable {
        case cue, agent, projects
    }

    /// iPhone（及窄窗口 iPad）用标签栏；宽 iPad 用分栏。
    enum Layout {
        case tabs, split
    }

    /// 新建（`project` 为 nil）或编辑项目的表单；书架、侧栏与项目页的入口都经这里，在根视图弹出。
    struct ProjectForm: Identifiable {
        let id = UUID()
        var project: Project?
    }

    /// 新会话输入框（`NewSessionInput`）；`project` 是先选中的项目（Agent 页筛着的），`launched` 是已经发出的那一次（再打开时接着看它的进度）。
    struct NewSession: Identifiable {
        struct Launched: Equatable, Sendable {
            var request: UUID
            var token: String
        }

        let id = UUID()
        var project: UUID?
        var launched: Launched?
        /// 从"发给 Agent"选了新会话：提示词的正文与补的话带过来作开场。
        var draft: ComposerDraft?
        /// 为哪条提示词开的（发给 Agent 时定下）：开好后关联它。
        var card: UUID?
        /// 显示的目标名：为提示词开的是它的任务的标题（`CueStore.handOffPlan`，与会话名同一条规则）；nil 时以项目名称呼。
        var name: String?
        /// 默认由哪台 Mac 开（`CueStore.handOffPlan` 定下的）；nil 是按项目的第一处绑定。
        var host: String?

        /// 默认在哪开：先选中的项目（有 `host` 时是它在那台 Mac 上的绑定），没有就是第一处。
        func place(among places: [ProjectFolders.LaunchPlace]) -> ProjectFolders.LaunchPlace? {
            project.flatMap { project in
                let own = places.filter { $0.project.id == project }
                return own.first { host != nil && $0.binding?.hostID == host } ?? own.first
            } ?? places.first
        }

        /// 在 `binding` 那台 Mac、它绑的文件夹用 `agent` 开新会话，`draft` 作开场：开好后关联 `card`（会话名按它定，`CueStore.requestLaunch`）
        /// （没有就是带上的第一张）。返回这一次的请求与认领标识。
        func launch(
            in project: Project, binding: DirectoryBinding, draft: ComposerDraft, agent: AgentKind, services: AppServices
        ) async throws -> Launched {
            let token = UUID().uuidString
            let opening = try draft.stored(in: services.store.files).nonEmpty
            let request = try await services.launch(
                PiLaunch(project: project.id, prompt: opening, token: token, agent: agent), title: name ?? project.name, on: binding.hostID,
                card: card ?? draft.attachments.first?.card)
            return Launched(request: request.id, token: token)
        }
    }

    var layout: Layout = .tabs
    var tab: Tab = .cue
    var cuePath: [Route] = []
    var agentPath: [Route] = []
    var projectsPath: [Route] = []
    /// 随手记里正在写的这一条：输入框收起后仍留着（见 `endCapture`）；没换过落点时落在正在看的项目（`currentProject`）。
    var capture = CaptureState()
    /// 随手记输入框浮在键盘上方。
    private(set) var capturing = false

    /// 有浮在键盘上方的输入框（随手记、新会话、发给 Agent）。
    var floating: Bool { capturing || newSession != nil || outbox != nil }
    var outbox: Outbox? {
        didSet { if let outbox, outbox.id != oldValue?.id { handOffDraft = ComposerDraft(attachments: [outbox]) } }
    }
    /// 发给 Agent 输入框的草稿（换了一条提示词就重来）：放在这里而不在输入框里，发出即收起后写库失败还能放回、重新浮起。
    var handOffDraft = ComposerDraft()
    var projectForm: ProjectForm?
    var newSession: NewSession?
    /// 分栏：侧栏选中的页与其上推入的页（打开的卡片纸页盖在项目页上）。
    var splitRoot: Route = .shelf
    var splitPath: [Route] = []
    var sidebar: NavigationSplitViewVisibility = .automatic
    /// 分栏：右侧的 Agent 面板是否展开。
    var agentPanel = false
    /// 各会话回复框的草稿（按会话记录 id），回复框的唯一事实源：离开会话再回来还在；文字另存在本机偏好、跨退出保留，
    /// 带上的卡片与图片只留在这次运行。"发到 Mac"带来的卡片或任务也写进这里。
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// 当前项目：正在看的项目页（含其上推入的页，如卡片纸页、项目页进的任务页），否则没有（未分类）。iOS 上"在哪个项目"
    /// 只有这一份——书架点进项目只改路径；随手记、任务页新建任务、⌘N 的默认落点都读它。
    var currentProject: UUID? {
        let visible: [Route] = switch layout {
        case .split: [splitRoot] + splitPath
        case .tabs: tab == .projects ? projectsPath : []
        }
        for route in visible.reversed() {
            if case .project(let id) = route { return id }
        }
        return nil
    }

    /// 标签栏布局：此刻这个标签推入的页。
    private var path: [Route] {
        get {
            switch tab {
            case .cue: cuePath
            case .agent: agentPath
            case .projects: projectsPath
            }
        }
        set {
            switch tab {
            case .cue: cuePath = newValue
            case .agent: agentPath = newValue
            case .projects: projectsPath = newValue
            }
        }
    }

    /// 屏上最上面的是独占底部的页（卡片纸页、会话页：编辑工具栏、回复框在底部）：iPhone 收起底部栏。只从路径推出，
    /// 不按页面出现、消失计数——那种计数在页面没走完消失回调就被拆掉时（浮窗收起的同时推入一页）会漏扣，底部栏就再也回不来。
    var ownsBottom: Bool { layout == .tabs && path.last?.ownsBottom == true }

    /// 在当前位置推入一页。
    func push(_ route: Route) {
        switch layout {
        case .split: splitPath.append(route)
        case .tabs: path.append(route)
        }
    }

    /// 发给 Agent：浮起发给 Agent 的输入框，正文带在里面（`HandOffInput`）。
    func handToAgent(_ card: Card, text: String? = nil) {
        outbox = Outbox(content: text ?? Outgoing.text(of: card), card: card.id, project: card.projectID)
    }

    /// 发给 Agent 时选了新会话：收起发给 Agent 的输入框，换成新会话的，草稿带过去。
    /// 在哪开、由哪台 Mac 开、会话名按交到哪的决定（`plan`）；未分类的没有项目可开，用输入框自己的默认。
    func handOffToNewSession(_ draft: ComposerDraft, card: UUID?, plan: HandOffPlan?) {
        let (project, host): (UUID?, String?) =
            switch plan?.destination {
            case .launch(let project, let host): (project, host)
            case .noFolder(let project, _): (project, nil)
            default: (outbox?.project, nil)
            }
        outbox = nil
        newSession = NewSession(project: project, draft: draft, card: card, name: plan?.name, host: host)
    }

    /// 分栏：侧栏选中一页，清掉其上推入的页。
    func select(_ route: Route) {
        splitRoot = route
        splitPath = []
    }

    /// 分栏：恢复窗口时选回上次侧栏选中的项目；它已不在项目目录里（进了回收站、被删）时留在书架。
    /// 分栏只在目录读到后才建出（`CatalogGate`），这里当场判定，不先推一张空的项目页再退回。
    /// 已经选着它时不动：分栏随窗口宽窄重建（宽 → 窄 → 宽）时，项目页上推入的页留着。
    func restore(project: UUID?, catalog: ProjectCatalog?) {
        guard let project, splitRoot != .project(project), catalog?.project(project) != nil else { return }
        select(.project(project))
    }

    /// 分栏：进入搜索前所在的页（含其上推入的页），退出搜索时回到这里。
    private var beforeSearch: (root: Route, path: [Route])?

    /// 每次 ⌘K（或点侧栏的搜索）加一：搜索页据此聚焦搜索框并全选已有文字，已在搜索页时同样生效。
    private(set) var searchFocusRequests = 0
    /// 标签栏布局下 ⌘K 要聚焦哪一页的搜索（灵感根页顶上一排，或某个项目页的下拉搜索）；那一页聚焦后清掉。
    var pendingPageSearch: Route?

    /// 标签栏布局的 ⌘K：有下拉搜索的只有项目页，正看着它就聚焦它的；其余页回到灵感根页，聚焦顶上一排的搜索框。
    func searchCurrentPage() {
        if tab == .projects, case .project? = projectsPath.last {
            pendingPageSearch = projectsPath.last
        } else {
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

    /// 项目进了回收站：从所有路径里移除它的页面。
    func pop(_ project: UUID?) {
        guard let project else { return }
        let gone = Route.project(project)
        for path in [\Navigation.cuePath, \.agentPath, \.projectsPath, \.splitPath] {
            if let index = self[keyPath: path].firstIndex(of: gone) { self[keyPath: path].removeSubrange(index...) }
        }
        if splitRoot == gone { select(.shelf) }
    }

    /// 小组件与分享扩展的链接：随手记、项目、卡片。
    func open(_ link: DeepLink) {
        switch link {
        case .capture(let project):
            startCapture(project: .some(project))
        case .project(let id):
            show(.project(id))
        case .card(let id):
            if layout == .tabs { tab = .projects }
            push(.card(id))
        case .cue:
            show(.cue)
        }
    }

    /// 点开的 Pi 通知：直接打开该会话的近况。
    func open(alert tap: PiAlertTap?) {
        if let tap { show(.session(tap.sessionState)) }
    }

    /// 去一页（通知、小组件、侧栏共用）：Cue 是 Cue 标签的根，会话的近况在 Agent 标签里（iPad 推入详情栏），其余在灵感标签里（iPad 选中侧栏）。
    /// 在项目页里要能返回项目的入口（任务页）用 `push`。
    func show(_ route: Route) {
        switch (route, layout) {
        case (.cue, .tabs):
            tab = .cue
            cuePath = []
        case (.agent, .tabs):
            tab = .agent
            agentPath = []
        case (.session, .tabs):
            tab = .agent
            agentPath = [route]
        case (.session, .split):
            if splitPath.last != route { splitPath.append(route) }
        case (_, .split): select(route)
        case (_, .tabs):
            tab = .projects
            projectsPath = [route]
        }
    }

    /// 这个会话的近况页此刻正在屏幕上：它是当前标签（iPad：详情栏）最上面的一页。
    func isViewing(session id: UUID) -> Bool {
        let top = switch layout {
        case .tabs: path.last
        case .split: splitPath.last
        }
        return top == .session(id)
    }

    /// 会话的前台提示（等你确认、做完了）弹不弹：正看着那个会话，或正看着 Agent 列表（那一行已经在变）时不弹。
    func showsAlert(about session: UUID) -> Bool {
        let onAgentList = switch layout {
        case .tabs: tab == .agent && agentPath.isEmpty
        case .split: splitRoot == .agent && splitPath.isEmpty
        }
        return !onAgentList && !isViewing(session: session)
    }

    /// 顶上那条提示还留不留：说的是某个会话的提示（等你确认、做完了），你进了那个会话或 Agent 列表就当场撤下
    /// （与不弹同一条规则 `showsAlert`），不在正看着的页面上停满 5 秒；别的提示照常留到时间。
    func keeps(_ notice: Workspace.Notice) -> Bool {
        guard case .session(let route)? = notice.link else { return true }
        return showsAlert(about: route.id)
    }

    /// 在当前位置推入一个会话的近况页（`sessionID` 是 Pi 的会话 id，记录已被删时用它读对话）；`draft` 带进它的回复框
    /// （发到 Mac 的卡片或任务），已经写的字留着。先读出这一页再推入：读库只要几毫秒，推入的第一帧就是标题与最新的对话；
    /// 先推入再读时，结果要等转场开始、主线程空出来才到，滑进来的前几帧是一张空页。读不出来时照常推入，由页面报错。
    func openSession(_ id: UUID, sessionID: String? = nil, draft: Outbox? = nil, store: CueStore) {
        outbox = nil
        if let draft {
            var reply = settings.replyDraft(for: id)
            reply.attachments = [draft]
            settings.setReplyDraft(reply, for: id)
        }
        Task {
            let seed = try? await SessionDigest.read(id, sessionID: sessionID, from: store)
            push(.session(id, sessionID: sessionID, seed: seed))
        }
    }

    /// Agent 标签页的项目筛选：上次选的（本机偏好）；选中的项目不在项目目录里（进了回收站）时是全部。
    func agentFilter(catalog: ProjectCatalog?) -> UUID? {
        settings.agentProject.flatMap { catalog?.project($0)?.id }
    }

    /// 在 Agent 标签页选了筛选：记下来。
    func chooseAgentFilter(_ project: UUID?) { settings.agentProject = project }

    /// 浮起随手记输入框；`project` 是入口指定的落点（小组件），不给时接着上次留下的草稿与落点。
    func startCapture(project: UUID?? = nil) {
        if let project { capture.project = project }
        capturing = true
    }


    /// 收起随手记：写了东西就留着下次接着写，空的连同换过的种类与落点一起丢掉。
    func endCapture() {
        capturing = false
        if capture.draft.isEmpty(accepting: .images) { capture = CaptureState() }
    }

    /// 记下了：清空并收起。
    func finishCapture() {
        capture = CaptureState()
        capturing = false
    }

}

extension Route {
    var isCard: Bool { if case .card = self { true } else { false } }

    /// 独占底部的页（卡片纸页、会话页：编辑工具栏、回复框在底部，在屏上时收起底部栏，见 `Navigation.ownsBottom`）。
    var ownsBottom: Bool {
        switch self {
        case .card, .session: true
        default: false
        }
    }

    /// 页顶上自带一排搜索与圆钮（`SearchRow`）：内容让到那一排下面，离栏的距离由那一页自己给。
    var hasSearchRow: Bool {
        switch self {
        case .shelf, .agent, .projectSessions: true
        default: false
        }
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
