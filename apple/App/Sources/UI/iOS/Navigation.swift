#if os(iOS)
import CueStore
import CueSync
import Foundation
import Observation
import SwiftUI

/// iOS 的导航状态：标签（灵感 / Agent）、各标签的推入路径、随手记、发到 Mac 与项目表单、iPad 的右侧 Agent 面板。
/// 数据不在这里，页面直接订阅 Store；共用的页面状态（提示、项目目录）在 `Workspace`。当前项目只从路径推出（`currentProject`）。
@MainActor @Observable
final class Navigation {
    enum Tab: Hashable {
        case projects, agent
    }

    /// iPhone（及窄窗口 iPad）用标签栏；宽 iPad 用分栏。
    enum Layout {
        case tabs, split
    }

    /// 要交给 Agent 的一条提示词（存储格式，变量已填）：浮起交给 Agent 的输入框（`HandOffInput`），选会话、补一句再发出。
    struct OpenTask: Identifiable {
        let id: UUID
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
        /// 从"交给 Agent"选了新会话：提示词的正文与补的话带过来作开场。
        var draft: ComposerDraft?
        /// 为哪条提示词开的（交给 Agent 时定下）：开好后关联它。
        var card: UUID?
    }

    var layout: Layout = .tabs
    var tab: Tab = .projects
    var projectsPath: [Route] = []
    var agentPath: [Route] = []
    /// 随手记里正在写的这一条：输入框收起后仍留着（见 `endCapture`）；没换过落点时落在正在看的项目（`currentProject`）。
    var capture = CaptureState()
    /// 随手记输入框浮在键盘上方。
    private(set) var capturing = false

    /// 有浮在键盘上方的输入框（随手记、新会话、交给 Agent；任务浮窗开着时交给 Agent 由浮窗自己浮起）。
    var floating: Bool { capturing || newSession != nil || (task == nil && outbox != nil) }
    var outbox: Outbox?
    /// 浮起的任务（`TaskSheet`）。
    var task: OpenTask?
    var projectForm: ProjectForm?
    var newSession: NewSession?
    /// 屏幕上独占底部的页（卡片纸页、Pi 会话页，推入途中起、返回开始止）的个数：iPhone 此时隐藏标签栏，
    /// 编辑工具栏与回复框不和标签栏叠在一起。计数而不是开关：从一页切到另一页时两边的出现与消失先后不定。
    var bottomPages = 0
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

    /// 在当前位置推入一页。
    func push(_ route: Route) {
        switch (layout, tab) {
        case (.split, _): splitPath.append(route)
        case (.tabs, .projects): projectsPath.append(route)
        case (.tabs, .agent): agentPath.append(route)
        }
    }

    func open(card id: UUID) {
        push(.card(id))
    }

    /// 交给 Agent：浮起交给 Agent 的输入框，正文带在里面（`HandOffInput`）。
    func handToAgent(_ card: Card, text: String? = nil) {
        outbox = Outbox(content: text ?? Outgoing.text(of: card), card: card.id, project: card.projectID)
    }

    /// 交给 Agent 时选了新会话：收起交给 Agent 的输入框，换成新会话的，草稿带过去。
    func handOffToNewSession(_ draft: ComposerDraft, card: UUID?) {
        let project = outbox?.project
        outbox = nil
        task = nil
        newSession = NewSession(project: project, draft: draft, card: card)
    }

    /// 任务在半屏浮窗里打开（书架"正在推进"、任务页、项目页的任务行）；灵感照旧推入整页纸。
    func openTask(_ id: UUID) {
        task = OpenTask(id: id)
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
        for path in [\Navigation.projectsPath, \.agentPath, \.splitPath] {
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
            show(project: id)
        case .card(let id):
            if layout == .tabs { tab = .projects }
            push(.card(id))
        }
    }

    /// 点开的 Pi 通知：直接打开该会话的近况。
    func open(alert tap: PiAlertTap?) {
        if let tap { show(session: tap.sessionState) }
    }

    /// 打开一个会话的近况（iPhone 在 Agent 标签里，iPad 推入详情栏）；通知与前台提示的去处。
    func show(session id: UUID) {
        switch layout {
        case .tabs:
            tab = .agent
            agentPath = [.session(id)]
        case .split:
            if splitPath.last != .session(id) { splitPath.append(.session(id)) }
        }
    }

    /// 这个会话的近况页此刻正在屏幕上：它是当前标签（iPad：详情栏）最上面的一页。
    func isViewing(session id: UUID) -> Bool {
        let top = switch layout {
        case .tabs: (tab == .agent ? agentPath : projectsPath).last
        case .split: splitPath.last
        }
        return top == .session(id)
    }

    /// 会话的前台提示（等你确认、做完了）弹不弹：正看着那个会话，或正看着 Agent 列表（那一行已经在变）时不弹。
    func showsAlert(about session: UUID) -> Bool {
        let onAgentList = switch layout {
        case .tabs: tab == .agent && agentPath.isEmpty
        case .split: agentPanel || (splitRoot == .agent && splitPath.isEmpty)
        }
        return !onAgentList && !isViewing(session: session)
    }

    /// 顶上那条提示还留不留：说的是某个会话的提示（等你确认、做完了），你进了那个会话或 Agent 列表就当场撤下
    /// （与不弹同一条规则 `showsAlert`），不在正看着的页面上停满 5 秒；别的提示照常留到时间。
    func keeps(_ notice: Workspace.Notice) -> Bool {
        guard case .session(let session) = notice.link else { return true }
        return showsAlert(about: session)
    }

    /// 在当前位置推入一个会话的近况页（`sessionID` 是 Pi 的会话 id，记录已被删时用它读对话）；`draft` 带进它的回复框
    /// （发到 Mac 的卡片或任务），已经写的字留着。先读出这一页再推入：读库只要几毫秒，推入的第一帧就是标题与最新的对话；
    /// 先推入再读时，结果要等转场开始、主线程空出来才到，滑进来的前几帧是一张空页。读不出来时照常推入，由页面报错。
    func openSession(_ id: UUID, sessionID: String? = nil, draft: Outbox? = nil, store: CueStore) {
        outbox = nil
        task = nil
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

    /// 打开未分类（iPhone 推入项目标签，iPad 选中侧栏）。
    func showInbox() {
        if layout == .split { select(.inbox) } else { tab = .projects; projectsPath = [.inbox] }
    }

    /// 打开任务页（iPhone 推入项目标签，iPad 选中侧栏）。在项目页里要能返回项目时用 `push(.tasks)`。
    func showTasks() {
        if layout == .split { select(.tasks) } else { tab = .projects; projectsPath = [.tasks] }
    }

    /// 打开项目页（iPhone 推入项目标签，iPad 选中侧栏）。
    func show(project id: UUID) {
        if layout == .split { select(.project(id)) } else { tab = .projects; projectsPath = [.project(id)] }
    }
}

extension Route {
    var isCard: Bool { if case .card = self { true } else { false } }

    /// 独占底部的页（卡片纸页、会话页：编辑工具栏、回复框在底部，在屏上时收起底部栏，见 `ownsBottomEdge`）。
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
