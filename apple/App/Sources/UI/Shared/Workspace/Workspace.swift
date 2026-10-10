#if os(macOS)
import CuePi
#endif
import CueStore
import Foundation
import Observation
import SwiftUI

/// 一个窗口（场景）的界面状态：项目目录、打开的卡、浮层、提示；Mac 另有选中的页与发送目标。数据本身不在这里，界面直接订阅 Store。
/// Mac 的当前项目只存在 `AppSettings.currentProject`（整个 App 一个），这里只记非项目页；iOS 的当前项目从导航路径推出（`Navigation.currentProject`）。
@MainActor @Observable
final class Workspace {
    #if os(macOS)
    nonisolated enum Page: Hashable {
        case project(UUID)
        case inbox
        case archive
        case trash
        /// Agent：全部会话的整页列表（Mac 侧栏 Agent 区的"全部"）。
        case agent
        /// 一个 Agent 会话的整页（Pi 的会话 id）。
        case session(String)
    }
    #endif

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: Dotted
        var isError: Bool
        /// 图标；nil 时按成功/错误用默认的。
        var symbol: String?
        /// 点提示去哪（如随手记的落点）；nil 时提示只是告知。
        var link: Link?
        /// 提示右边的一个动作：多是"撤销"（把刚才那一下拨回去），完成任务后是"归档"。
        var action: NoticeAction?
    }

    struct NoticeAction: Equatable {
        let id = UUID()
        let title: String
        /// 撤销刚才那一下（Mac 上 ⌘Z 也能点它）。
        var isUndo = false
        let run: @MainActor () async throws -> Void
        static func == (lhs: NoticeAction, rhs: NoticeAction) -> Bool { lhs.id == rhs.id }
    }

    /// 提示能带去的地方：项目页（nil 是未分类）。
    enum Link: Equatable {
        case project(UUID?)
        #if os(iOS)
        /// 一个 Pi 会话的近况页（会话记录 id）。
        case session(UUID)
        #endif
    }

    #if os(macOS)
    /// Pi 会话正忙时待用户选择马上说或等它做完再说的一次发送。
    struct BusySend {
        var text: String
        /// Pi 自己的会话 id（`AgentTarget.session`）
        var session: String
        var card: UUID?
    }
    #endif

    let services: AppServices
    /// 本窗口的项目目录；nil 表示还没读到或读取失败，根视图在读到之前不显示页面。
    private(set) var catalog: ProjectCatalog?
    /// 资料库读得出来（项目目录已读到）。没读到或读取失败时，凡是会写资料库的入口都不出现或不可用。
    var isLibraryReady: Bool { catalog != nil }
    /// 项目目录读取失败的原因；根视图据此显示错误与"重试"，不停在空白页上。
    private(set) var catalogFailure: String?
    /// 第几次订阅项目目录：根视图以它为 `.task` 的 id，`retryCatalog` 加一即重新订阅。
    private(set) var catalogAttempt = 0
    #if os(macOS)
    var sidebar: NavigationSplitViewVisibility = .all
    private(set) var nonProjectPage: Page?
    /// 打开的卡（编辑纸页；iOS 打开卡片是推入导航，见 `Navigation.open(card:)`）。设成某张卡时纸页立即挂上；
    /// 清空时纸页先缩回原卡片，缩完才卸下（见 `presentedCard`）。
    var openCard: UUID? {
        didSet { if let openCard { present(openCard) } }
    }
    /// 纸页挂在屏上的卡：比 `openCard` 晚一步清空，缩回卡片的动画期间仍在。
    private(set) var presentedCard: UUID?
    /// 各张卡在纸页开合中的状态，按卡分开（见 `CardPresence`）。
    @ObservationIgnored private var presences: [UUID: CardPresence] = [:]
    #endif
    /// 正在给它挑任务的灵感（"挂到任务"的选择面板，`TaskPicker`；两端各由窗口的根视图弹出）。
    var attaching: Card?
    #if os(macOS)
    /// 新建或编辑项目的表单（`ProjectForm`；侧栏与项目页的入口都经这里，主窗口弹出）。
    var projectForm: ProjectForm.Request?
    /// ⌘K 搜索开着（`SearchPalette`）。
    var searching = false
    /// 右上角的任务面板开着（`TasksPanel`）。
    var showsTasks = false
    /// 首次启动问要不要把 cuepad 命令行装进 PATH（`AppDelegate` 置起，主窗口弹出）。
    var offersCommandLineTool = false
    #endif
    var notice: Notice?
    /// 正在给哪个项目选文件夹（iOS：根视图据此弹候选；Mac 直接弹系统的选文件夹面板，不经这里）。
    var folderPicker: Project?

    /// 交给了会话的灵感与任务（`AgentLinks`，卡与行上的状态点读它）、文件夹绑定引导（`FolderGuide`）：整个窗口一份，页面直接读，
    /// 不各自订阅（挂着的页也不会在每次回到前台时重读一遍）。读到和已有的相同就不写，免得页面白算。
    private(set) var agentLinks = AgentLinks(items: [:], launching: [])
    private(set) var folderGuide: FolderGuide?

    func observeAgentLinks() async {
        do {
            for try await next in services.store.observe { try AgentLinks.read(from: $0) } where next != agentLinks {
                agentLinks = next
            }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    func observeFolderGuide() async {
        do {
            for try await next in services.store.observe { [host = localHost] in try FolderGuide.read(host: host, from: $0) }
            where next != folderGuide {
                folderGuide = next
            }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    #if os(macOS)
    /// 请底部输入栏聚焦的次数（空态的"记一条"）：输入栏的焦点在它自己那里，只看这个数变了就聚焦。
    private(set) var captureFocusRequests = 0
    func focusCapture() { captureFocusRequests += 1 }
    /// 鼠标停在哪张卡上、正按着哪张卡（卡片报上来的悬停与 AppKit 的鼠标事件，见 `mouse(down:)`）。不触发界面刷新。
    @ObservationIgnored private var hoveredCard: UUID?
    @ObservationIgnored private var pressedCard: UUID?
    private static let releaseGrace: Duration = .milliseconds(80)
    var busySend: BusySend?
    /// 用户在本窗口选过或发过的 Agent 会话；nil 或已失效时用本项目的会话（`agentTarget`）。
    var sendChoice: AgentTarget?
    /// 在线 Pi 会话（桥上的连接 id）各自归属的项目，由 Store 按工作目录判定（`project(containing:)`）；
    /// 会话或目录绑定变化时由根视图调用 `refreshSessionProjects` 重算。
    private(set) var sessionProjects: [String: UUID] = [:]
    /// 本机在线会话的摘要（Pi 自己的会话 id → 同步记录上的问与答）：桥上没有，界面把它配到桥上的实时状态上。
    /// 由 `observeSessionRecaps` 跟随同步记录。
    private(set) var sessionRecaps: [String: PiRecap] = [:]
    /// 发给在线会话的最近一条投送请求（Pi 的会话 id →），同一次观察带来：Mac 上配到桥的实时状态上算显示状态（`PiDelivery`）。
    private(set) var sessionDeliveries: [String: DeliveryRequest] = [:]
    /// 发给在线会话、没能送达的话有几句（Pi 的会话 id →，`PiSessionListItem.undelivered`）：会话行的小标记。
    private(set) var sessionUndelivered: [String: Int] = [:]
    /// 这个窗口打开之后在这台 Mac 上结束的会话（同步记录），最近结束的在前。可观察：默认发送目标在没有在线会话时取其中本项目最近结束的那个；
    /// 窗口打开前就已结束的历史会话不在其中。由 `observeSessionRecaps` 跟随。
    private(set) var recentlyEnded: [PiSessionState] = []
    @ObservationIgnored private let openedAt = Date()
    /// 只看最近结束的这么多个会话：要找的是刚结束的，历史会话有几千个。
    private nonisolated static let endedWindow = 20

    /// 鼠标进出一张卡。拖出卡片也就不再按着它（与按钮拖出即松开一致）。
    func hover(_ card: UUID, inside: Bool) {
        if inside {
            hoveredCard = card
        } else {
            if hoveredCard == card { hoveredCard = nil }
            if pressedCard == card { release() }
        }
    }

    /// AppKit 分发鼠标按下、松开时调用（本地事件监听，早于 SwiftUI 按钮识别按下）：按下时鼠标停着的那张卡在这一轮就显出按下，
    /// 点下的第一帧就有反馈。
    func mouse(down: Bool) {
        guard down else {
            // 松开到"打开中"接上之间隔着一两次更新：这时就放开，卡片会先弹一下再按回去（两段动画叠加还会压得更小）。
            // 稍等再放开；打开了就由"打开中"接着按住，没打开（取消）这时才回弹
            let card = pressedCard
            Task {
                try? await Task.sleep(for: Self.releaseGrace)
                if pressedCard == card { release() }
            }
            return
        }
        guard let card = hoveredCard else { return }
        pressedCard = card
        presence(of: card).pressing = true
    }

    private func release() {
        if let card = pressedCard { presence(of: card).pressing = false }
        pressedCard = nil
    }

    /// 会话页放在窗口工具栏上的标题与菜单（`SessionHeader`）。
    let sessionHeader = SessionHeader()

    /// 跟随同步记录里在线会话的摘要与发给它们的最近一条投送请求、以及刚结束的会话，直到任务取消。
    func observeSessionRecaps() async {
        struct Records: Equatable, Sendable {
            var live: [PiSessionListItem]
            var ended: [PiSessionListItem]
        }
        do {
            let observed = services.store.observe { store in
                Records(
                    live: try store.piSessionPage(.live).items,
                    ended: try store.piSessionPage(PiSessionQuery(scope: .ended, limit: Self.endedWindow)).items)
            }
            for try await records in observed {
                let items = records.live
                let ended = records.ended.map(\.state).filter { $0.hostID == services.hostID && $0.stateSince >= openedAt }
                if ended != recentlyEnded { recentlyEnded = ended }
                let recaps = Dictionary(items.map { ($0.state.sessionID, $0.state.recap) }) { first, _ in first }
                let deliveries = Dictionary(items.compactMap { item in item.delivery.map { (item.state.sessionID, $0) } }) { first, _ in first }
                let undelivered = PiSessionListItem.undelivered(items)
                if recaps != sessionRecaps { sessionRecaps = recaps }
                if deliveries != sessionDeliveries { sessionDeliveries = deliveries }
                if undelivered != sessionUndelivered { sessionUndelivered = undelivered }
            }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    /// 重算活着的会话各归哪个项目。
    func refreshSessionProjects() async {
        var result: [String: UUID] = [:]
        for session in services.pi.sessions {
            do {
                if let project = try await services.store.project(containing: session.cwd) { result[session.id] = project.id }
            } catch {
                fail(error)
                return
            }
        }
        sessionProjects = result
    }

    #endif

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(services: AppServices) {
        self.services = services
    }

    #if os(macOS)
    var page: Page {
        if let nonProjectPage { return nonProjectPage }
        return (services.settings.currentProject ?? defaultProject).map(Page.project) ?? .inbox
    }

    /// 没打开过项目（第一次打开、打开过的进了回收站）时首屏是项目目录顺序的第一个：由目录当场推出、不写进"上次打开"，
    /// 项目陆续同步进来时跟着目录走；只有用户切换项目才记下（`show`）。
    private var defaultProject: UUID? { catalog?.projects.first?.id }

    /// 当前项目（未分类为 nil）。回收站页没有项目。
    var currentProject: UUID? {
        if case .project(let id) = page { id } else { nil }
    }

    /// 内容区挂着的页（`PageStack`）：去过的页留着，回访不再重建；至多 `keptPages` 个，满了换掉最久没看的。会话页不留（带着输入焦点与实时对话，挂着不看会抢键盘）。
    private(set) var kept: [Page] = []
    @ObservationIgnored private var lastSeen: [Page: Int] = [:]
    @ObservationIgnored private var visits = 0
    @ObservationIgnored private var trimTask: Task<Void, Never>?
    static let keptPages = 4

    /// 侧栏开合的动画里（约 0.2 秒）。页面此刻不接指针（`PageStack`）：分栏每帧挪动详情区，AppKit 每帧重算整窗的鼠标跟踪区、重设指针，
    /// 页面里每个悬停区都要重算（大项目页开一次侧栏多约 120ms 主线程、掉帧 5～8 次，页面不接指针后只剩约 45ms）；这几百毫秒里页面本来也不该响应指针。
    /// 纸页放大缩回是图层动画、不挪 AppKit 视图，量过没有这笔开销。
    private(set) var sidebarMoving = false
    @ObservationIgnored private var sidebarMovingTask: Task<Void, Never>?

    /// 刚离开的页：切页的那一帧它已经看不见，但"不在前台"（暂停订阅、停读实时状态）晚两帧才生效——页面重新求值要几十毫秒，不放在点击的回合里。
    private(set) var leaving: Page?

    /// 此刻挂着的页：留着的加上当前页（首屏、目录纠正出来的页还没经过 `show`；会话页只在是当前页时在里面）。
    var mountedPages: [Page] { kept.contains(page) ? kept : kept + [page] }

    private func keep(_ page: Page) {
        if case .session = page { return }
        visits += 1
        lastSeen[page] = visits
        guard !kept.contains(page) else { return }
        kept.append(page)
        // 多出来的页不在这次点击里卸：卸一整页的视图树要几十毫秒，等切页的那一帧出去、安静下来再卸；连着去了很多页时先卸
        if kept.count > Self.keptPages + 2 { trim() } else { scheduleTrim() }
    }

    private func scheduleTrim() {
        trimTask?.cancel()
        trimTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.trim()
        }
    }

    /// 只留最近看过的 `keptPages` 页，当前页一定留着。
    private func trim() {
        let current = page
        let stale = kept.filter { $0 != current }.sorted { lastSeen[$0, default: 0] < lastSeen[$1, default: 0] }.prefix(max(0, kept.count - Self.keptPages))
        if !stale.isEmpty { kept.removeAll { stale.contains($0) } }
    }

    /// 进了回收站或删掉的项目不再留着它的页。
    private func forget(projectsNotIn ids: Set<UUID>) {
        let gone = kept.filter { if case .project(let id) = $0 { !ids.contains(id) } else { false } }
        if !gone.isEmpty { kept.removeAll { gone.contains($0) } }
    }

    /// 纸页缩回动画结束。
    func finishClosingCard() {
        guard openCard == nil else { return }
        dismissPresented()
    }

    /// 纸接过原卡片、开始放大。
    func cover(_ card: UUID) {
        presence(of: card).phase = .covered
    }

    /// 纸页缩回到原卡片、自己隐去的同一帧：原卡片回来（纸页稍后才卸下）。
    func uncover(_ card: UUID) {
        presence(of: card).phase = .returned
    }

    /// 这张卡在纸页开合中的状态；卡片视图只观察自己的那一个。
    func presence(of card: UUID) -> CardPresence {
        if let presence = presences[card] { return presence }
        let presence = CardPresence()
        presences[card] = presence
        return presence
    }

    private func present(_ card: UUID) {
        guard presentedCard != card else { return }
        dismissPresented()
        presentedCard = card
        presence(of: card).phase = .opening
    }

    private func dismissPresented() {
        if let card = presentedCard { presence(of: card).reset() }
        presentedCard = nil
    }

    /// 切到一页（侧栏点哪就是哪）；开着的纸页随之收起。没有历史，也没有上一层：Mac 的导航都在侧栏。
    func show(_ page: Page) {
        openCard = nil
        dismissPresented()
        let left = self.page
        keep(left)
        keep(page)
        if left != page {
            leaving = left
            Task { [weak self] in
                await NextFrame.wait()
                await NextFrame.wait()
                if self?.leaving == left { self?.leaving = nil }
            }
        }
        if case .project(let id) = page {
            nonProjectPage = nil
            services.settings.currentProject = id
        } else {
            nonProjectPage = page
        }
    }

    func toggleSidebar() {
        sidebar = sidebar == .detailOnly ? .all : .detailOnly
        // AppKit 的分栏动画约 0.2 秒
        sidebarMoving = true
        sidebarMovingTask?.cancel()
        sidebarMovingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            if !Task.isCancelled { self?.sidebarMoving = false }
        }
    }
    #endif

    // MARK: 提示

    static let noticeDuration: Duration = .seconds(2.4)

    func say(
        _ text: Dotted, isError: Bool = false, symbol: String? = nil, link: Link? = nil, duration: Duration = Workspace.noticeDuration,
        undo: (@MainActor () async throws -> Void)? = nil
    ) {
        say(
            text, isError: isError, symbol: symbol, link: link, duration: duration,
            action: undo.map { NoticeAction(title: "撤销", isUndo: true, run: $0) })
    }

    func say(
        _ text: Dotted, isError: Bool = false, symbol: String? = nil, link: Link? = nil, duration: Duration = Workspace.noticeDuration,
        action: NoticeAction?
    ) {
        let notice = Notice(text: text, isError: isError, symbol: symbol, link: link, action: action)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            if self?.notice == notice { self?.notice = nil }
        }
    }

    func fail(_ error: any Error) {
        say(Dotted(error.localizedDescription), isError: true)
    }

    // MARK: 项目目录、当前项目与新建位置

    /// 订阅项目目录，直到所在任务取消（根视图在 `.task(id: catalogAttempt)` 里调用）；Mac 上项目增删时核对当前项目。
    /// 读取失败时清空目录并记下原因：资料库读不出来时不能接着显示过时的项目。
    func observeCatalog() async {
        catalogFailure = nil
        do {
            #if DEBUG
            try DebugScene.injectCatalogFailure(attempt: catalogAttempt)
            #endif
            for try await next in services.store.observe { try ProjectCatalog.read(from: $0) } {
                let membershipChanged = catalog.map { Set($0.projects.map(\.id)) != Set(next.projects.map(\.id)) } ?? true
                catalog = next
                if membershipChanged {
                    #if os(macOS)
                    forget(projectsNotIn: Set(next.projects.map(\.id)))
                    await reconcileCurrentProject()
                    #endif
                }
            }
        } catch is CancellationError {
        } catch {
            catalog = nil
            catalogFailure = error.localizedDescription
        }
    }

    func retryCatalog() {
        catalogAttempt += 1
    }

    #if os(macOS)
    /// 保存的当前项目以 Store 为准：不存在或已进回收站时清掉设置（首屏由目录推出，见 `defaultProject`）。
    /// 项目表每次变化后、写入撞上失效项目时调用。
    func reconcileCurrentProject() async {
        let settings = services.settings
        guard let saved = settings.currentProject else { return }
        do {
            let projects = try await services.store.projects()
            guard !projects.contains(where: { $0.id == saved }) else { return }
            if settings.currentProject == saved { settings.currentProject = nil }
        } catch {
            fail(error)
        }
    }
    #endif

    /// 新建卡片。项目是否有效由 Store 在写事务里判定：项目已不存在或在回收站（`invalidProject`）时，
    /// 重新核对当前项目，卡片落到未分类并提示，不会写进看不见的地方。
    func createCard(body: String = "", in project: UUID?) async throws -> Card {
        let store = services.store
        return try await fallingBack(from: project) { try await store.createCard(in: $0, body: body) }
    }

    /// 新建任务；项目失效时同样回落，任务归为未分类并提示。
    func createTask(_ body: String, in project: UUID?) async throws -> Card {
        let store = services.store
        return try await fallingBack(from: project) { try await store.createTask(body, in: $0) }
    }

    private func fallingBack<T>(from project: UUID?, _ write: (UUID?) async throws -> T) async throws -> T {
        do {
            return try await write(project)
        } catch CueStoreError.invalidProject where project != nil {
            #if os(macOS)
            await reconcileCurrentProject()
            #endif
            let result = try await write(nil)
            say("原项目已不存在或在回收站，已放到未分类", isError: true)
            return result
        }
    }

    /// 点任务的圆圈：待办与进行中都变完成，完成的回到待办。下一个状态按 Store 的当前值决定，不看界面手里的副本：
    /// 副本可能已过时（列表还没刷新就又点了一次），按它推算会把已勾的再勾一次。
    func toggle(_ task: Card) async throws {
        let store = services.store, id = task.id
        let current = try await store.card(id)?.status
        try await store.setStatus(id, current == .done ? .todo : .done)
        // 做完了就给一个归档（不自动归档）
        if current != .done { say("已完成", action: NoticeAction(title: "归档") { try await self.archive(id) }) }
    }

    /// 挪动卡片（拖放、缩进、反缩进、挂成提示词）；下级随它走。
    func move(_ id: UUID, _ move: TaskMove) {
        perform { try await $0.moveCard(id, to: move.slot, after: move.after) }
    }

    /// 开始做（待办 → 进行中）；`back` 为 true 时停下回到待办。
    func start(_ task: Card, back: Bool = false) async throws {
        try await services.store.setStatus(task.id, back ? .todo : .inProgress)
    }

    /// 设为任务 / 改回灵感（改回时下级提到它的位置）。提示里带"撤销"，点了就拨回去：多行的灵感设为任务时拆出的那条提示词
    /// 原样合回正文。
    func setTodo(_ id: UUID, _ on: Bool) async throws {
        let store = services.store
        let body = try await store.card(id)?.body
        let prompt = try await store.setTodo(id, on)
        say(on ? "已设为任务" : "已改回灵感", undo: {
            if let prompt, let body {
                try await store.purgeCard(prompt.id)
                try await store.updateCard(id) { $0.body = body }
            }
            try await store.setTodo(id, !on)
        })
    }

    /// 任务下写一条提示词：先建一条空的接在下级最后，调用方随即打开它的编辑；离开时还是空白由 `leaveEditing` 删掉。
    func createPrompt(under task: UUID) async throws -> Card {
        try await services.store.createCard(body: "", under: task)
    }

    /// 离开一条灵感或提示词的编辑：先写下没保存的字，还是空白（`Card.isBlank`）就不留下——记一条与写提示词都是先建一条空的再编辑。
    func leaveEditing(_ id: UUID, flush: Autosave?) {
        let store = services.store
        attempt {
            await flush?.flush()
            try await store.dropIfBlank(id)
        }
    }

    /// 归档（连同下级）：不占列表、仍可搜；提示里可撤销。
    func archive(_ id: UUID) async throws {
        let store = services.store
        try await store.archive(id)
        #if os(macOS)
        if openCard == id { openCard = nil }
        #endif
        say("已归档", undo: { try await store.unarchive(id) })
    }

    /// 删除一条灵感或任务（进回收站，下级提到它的位置，见 `CueStore.trashCard`）：提示里可撤销，撤销时下级回到它下面。
    func trash(_ id: UUID) async throws {
        let store = services.store
        let children = try await store.children(of: id).map(\.id)
        try await store.trashCard(id)
        #if os(macOS)
        if openCard == id { openCard = nil }
        #endif
        say("已删除", undo: {
            try await store.restoreCard(id)
            var previous: UUID?
            for child in children {
                try await store.moveCard(child, to: .under(id), after: previous)
                previous = child
            }
        })
    }

    /// 一键归档"最近完成"的任务。
    func archiveCompletedTasks() async throws {
        let count = try await services.store.archiveCompletedTasks()
        if count > 0 { say("已归档 \(count) 项任务") }
    }

    /// 从灵感里挑一条挂到任务下（成为它的提示词），排在已有下级之后。
    func attach(_ idea: UUID, to task: UUID) async throws {
        let last = try await services.store.children(of: task).last?.id
        try await attach(idea, TaskMove(slot: .under(task), after: last))
    }

    /// 灵感挂到任务下成为提示词（挑一条或拖到任务上）：提示里的撤销把它放回原来所在的项目、原来的位置。
    func attach(_ idea: UUID, _ move: TaskMove) async throws {
        let store = services.store
        guard let card = try await store.card(idea) else { throw CueStoreError.notFound }
        let siblings = try await store.cards(in: card.projectID).map(\.id)
        let before = siblings.firstIndex(of: idea).flatMap { $0 > 0 ? siblings[$0 - 1] : nil }
        try await store.moveCard(idea, to: move.slot, after: move.after)
        say("已成为任务的提示词", undo: { try await store.moveCard(idea, to: .top(project: card.projectID), after: before) })
    }

    /// 复制正文（存储格式，变量已填）到剪贴板：普通的复制，不是发送，不记发送记录。
    func copy(_ stored: String) {
        do {
            try services.copy(stored)
            say("已复制")
        } catch {
            fail(error)
        }
    }

    /// 界面上的设为任务 / 改回灵感：失败时提示。
    func toggleTodo(_ id: UUID, _ on: Bool) {
        attempt { try await self.setTodo(id, on) }
    }

    /// 点提示里的动作（撤销、归档）：收起提示，做那件事。
    func run(_ action: NoticeAction) {
        notice = nil
        attempt { try await action.run() }
    }

    /// 请会话所在的 Mac 结束它。进度（正在结束、没能结束的原因）只来自这条结束请求，界面按 `DeliveryRequest.shownEnd` 读；
    /// 还在路上时再点不会再发一条（Store 去重）。写不进请求时提示。
    func end(_ session: PiSessionState) async {
        do { _ = try await services.end(session) } catch { fail(error) }
    }

    /// 执行一个异步操作，失败时提示。
    func attempt(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await work() } catch { fail(error) }
        }
    }

    /// 执行一个 Store 写操作，失败时提示。
    func perform(_ work: @escaping @Sendable (CueStore) async throws -> Void) {
        let store = services.store
        Task {
            do { try await work(store) } catch { fail(error) }
        }
    }
}

#if os(macOS)
/// 一张卡在纸页开合中的状态（Mac 的纸页开合）。按卡分开、各自可观察：开合时只有被打开的那张卡的视图重算，
/// 墙上其余卡片与"更早"各行不受牵动（大项目里有上千张）。
@MainActor @Observable
final class CardPresence {
    enum Phase {
        /// 没有打开。
        case idle
        /// 刚点开、纸页还在准备：原卡片保持按下的样子，纸从这个样子起飞。
        case opening
        /// 纸接过了原卡片（同一帧纸以原卡片按下的样子出现在它的位置上）：原卡片隐去，开合全程屏幕上只有一份这张卡的字。
        case covered
        /// 纸缩回原卡片、自己隐去：原卡片回来（不再按下），纸页下一帧卸下。
        case returned
    }

    fileprivate(set) var phase = Phase.idle
    /// 鼠标正按着这张卡（Mac，见 `Workspace.mouse(down:)`）。
    fileprivate(set) var pressing = false
    /// 卡在屏幕上的位置（全局坐标），纸页从这里放大、缩回到这里；只在跟踪期间更新，不触发界面刷新。
    @ObservationIgnored var frame: CGRect?

    /// 纸页挂着期间才跟踪这张卡的位置：时时跟踪的话，滚动时每一帧都要为每张卡换算一次位置。
    var isTracked: Bool { phase != .idle }
    var covered: Bool { phase == .covered }
    /// 原卡片显出按下的样子（见 `CardOpenStyle`）：鼠标按着，或已打开、纸页还在准备。
    var held: Bool { pressing || phase == .opening }

    fileprivate func reset() {
        phase = .idle
        frame = nil
    }
}
#endif
