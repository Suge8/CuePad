#if os(iOS)
import CueStore
import CueSync
import Foundation
import Observation
import SwiftUI

/// iOS 的导航状态，三种宽度同一个状态机：侧栏选中的页（`root`）与其上推入的页（`path`），iPhone 上分栏折叠后此刻在列表还是在页里（`column`），
/// 外加发到 Mac 与项目表单、iPad 的右侧 Cue 面板。数据不在这里，页面直接订阅 Store；共用的页面状态（提示、项目目录）在 `Workspace`。
/// 当前项目只从路径推出（`currentProject`）。
@Observable
final class Navigation {
    /// 新建（`project` 为 nil）或编辑项目的表单；书架、侧栏与项目页的入口都经这里，在根视图弹出。
    struct ProjectForm: Identifiable {
        let id = UUID()
        var project: Project?
        /// 新建好之后接着做的（从新会话来的：开新会话的输入框）。
        var created: ((UUID) -> Void)?
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
        /// 从"发给 Agent"选了新会话：任务的正文与补的话带过来作开场。
        var draft: ComposerDraft?
        /// 为哪件任务开的（发给 Agent 时定下）：开好后关联它。
        var card: UUID?
        /// 显示的目标名：为任务开的是它的标题（`CueStore.handOffPlan`，与会话名同一条规则）；nil 时以项目名称呼。
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

    /// 侧栏选中的页（宽屏右边那一栏、iPhone 从列表推进去那一层的根）：打开 App 先到 Cue。
    var root: Route = .cue
    /// 根页上推入的页（打开的卡片纸页、会话页……）。
    var path: [Route] = []
    /// iPhone（与窄窗口 iPad）上分栏折叠成一层层的页：此刻在页里（`.detail`，根页与其上推入的页）还是在列表（`.sidebar`）。
    /// 打开 App 就在页里（Cue）；系统的返回与左缘右滑回到列表时由系统改成 `.sidebar`。宽屏两栏都在，一直是 `.detail`（变宽时 `IOSRoot` 改回）。
    var column: NavigationSplitViewColumn = .detail
    /// 每次请"对 Cue 说"拿到焦点（⌘⇧N、随手记小组件）加一：Cue 页的输入框看它变了就聚焦。
    private(set) var cueFocusRequests = 0

    /// 这个窗口有系统菜单开着（`MenuButton`）：这段里贴着键盘的那一层不跟键盘走（`KeyboardHold`）。
    var menuOpen = false
    /// 有浮在键盘上方的输入框（新会话、发给 Agent）。
    var floating: Bool { newSession != nil || outbox != nil }
    var outbox: Outbox? {
        didSet { if let outbox, outbox.id != oldValue?.id { handOffDraft = ComposerDraft(attachments: [outbox]) } }
    }
    /// 发给 Agent 输入框的草稿（换了一件任务就重来）：放在这里而不在输入框里，发出即收起后写库失败还能放回、重新浮起。
    var handOffDraft = ComposerDraft()
    var projectForm: ProjectForm?
    var newSession: NewSession?
    var sidebar: NavigationSplitViewVisibility = .automatic
    /// 宽屏：右侧的 Cue 面板是否展开。
    var agentPanel = false
    /// 各会话回复框的草稿（按会话记录 id），回复框的唯一事实源：离开会话再回来还在；文字另存在本机偏好、跨退出保留，
    /// 带上的卡片与图片只留在这次运行。"发到 Mac"带来的卡片或任务也写进这里。
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// 当前项目：正在看的项目页（含其上推入的页，如卡片纸页、项目页进的任务页），否则没有（未分类）。iOS 上"在哪个项目"
    /// 只有这一份——列表或书架点进项目只改路径；任务页新建任务、⌘N 的默认落点都读它。
    var currentProject: UUID? {
        for route in ([root] + path).reversed() {
            if case .project(let id) = route { return id }
        }
        return nil
    }

    /// 在当前页上推入一页（iPhone 在列表上时连同当前页一起推进去）。
    func push(_ route: Route) {
        path.append(route)
        column = .detail
    }

    /// 开新会话的输入框。会话开在项目的文件夹里：还没有项目时先新建项目，建好接着开这个项目的新会话（入口只有这一处，输入框不再另写没有项目的样子）。
    func startNewSession(_ start: NewSession = .init(), hasProjects: Bool) {
        guard hasProjects else {
            projectForm = ProjectForm(created: { [weak self] id in self?.newSession = NewSession(project: id) })
            return
        }
        newSession = start
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

    /// 侧栏选中一页，清掉其上推入的页；iPhone 上推进那一页。
    func select(_ route: Route) {
        root = route
        path = []
        column = .detail
    }

    /// iPhone：回到列表，效果同系统的返回与左缘右滑。界面上不调它（返回交给系统），只给调试画面（sidebar）与交互测量（"回到列表"一步）。
    func showList() { column = .sidebar }

    /// 宽屏：恢复窗口时选回上次侧栏选中的项目；它已不在项目目录里（进了回收站、被删）时留在书架。
    /// 分栏只在目录读到后才建出（`CatalogGate`），这里当场判定，不先推一张空的项目页再退回。
    /// 已经选着它时不动：分栏随窗口宽窄重建（宽 → 窄 → 宽）时，项目页上推入的页留着。
    func restore(project: UUID?, catalog: ProjectCatalog?) {
        guard let project, root != .project(project), catalog?.project(project) != nil else { return }
        select(.project(project))
    }

    /// 进入搜索前所在的页（含其上推入的页），退出搜索时回到这里。
    private var beforeSearch: (root: Route, path: [Route])?

    /// 每次 ⌘K（或点列表顶上的搜索框）加一：搜索页据此聚焦搜索框并全选已有文字，已在搜索页时同样生效。
    private(set) var searchFocusRequests = 0

    /// 去搜索页并聚焦搜索框。
    func openSearch() {
        searchFocusRequests += 1
        column = .detail
        guard root != .search else { return }
        beforeSearch = (root, path)
        select(.search)
    }

    /// 退出搜索，回到进入前的页；没有记录时回到书架。
    func closeSearch() {
        guard root == .search else { return }
        let back = beforeSearch ?? (.shelf, [])
        beforeSearch = nil
        root = back.root
        path = back.path
    }

    /// 项目进了回收站：从路径里移除它的页面。
    func pop(_ project: UUID?) {
        guard let project else { return }
        let gone = Route.project(project)
        if let index = path.firstIndex(of: gone) { path.removeSubrange(index...) }
        if root == gone { select(.shelf) }
    }

    /// 小组件与分享扩展的链接：对 Cue 说、项目、卡片。
    func open(_ link: DeepLink) {
        switch link {
        case .speak:
            speakToCue()
        case .project(let id):
            show(.project(id))
        case .card(let id):
            push(.card(id))
        case .cue:
            show(.cue)
        }
    }

    /// 点开的 Pi 通知：直接打开该会话的近况。
    func open(alert tap: PiAlertTap?) {
        if let tap { show(.session(tap.sessionState)) }
    }

    /// 去 Cue 页并让"对 Cue 说"拿到焦点（⌘⇧N、随手记小组件）：要做事、随手记都从这里说。
    func speakToCue() {
        show(.cue)
        cueFocusRequests += 1
    }

    /// 去一页（通知、小组件、提示共用）：会话的近况推在当前页上（返回回到原处），搜索经 `openSearch`，其余选中侧栏那一页。
    /// 在项目页里要能返回项目的入口（任务页）用 `push`。
    func show(_ route: Route) {
        switch route {
        case .session:
            if path.last != route { path.append(route) }
            column = .detail
        case .search: openSearch()
        default: select(route)
        }
    }

    /// 此刻屏幕上右边那一栏最上面的页；iPhone 回到了列表时没有。
    private var top: Route? { column == .detail ? path.last ?? root : nil }

    /// 这个会话的近况页此刻正在屏幕上。
    func isViewing(session id: UUID) -> Bool { top == .session(id) }

    /// 会话的前台提示（等你确认、做完了）弹不弹：正看着那个会话，或正看着 Agent 整页（那一行已经在变）时不弹。
    func showsAlert(about session: UUID) -> Bool { top != .agent && !isViewing(session: session) }

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

}

extension Route {
    var isCard: Bool { if case .card = self { true } else { false } }

    /// 页顶上自带一排（搜索页的搜索框与范围、Cue 页头）：内容让到那一排下面，离栏的距离由那一页自己给。
    var ownsTopBar: Bool { self == .search || self == .cue }
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
