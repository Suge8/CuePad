#if os(macOS)
import CuePi
#endif
import CueStore
import Foundation
import Observation
import SwiftUI

/// 一个窗口（场景）的界面状态：项目目录、打开的卡、浮层、提示；Mac 另有选中的页与发送目标。数据本身不在这里，界面直接订阅 Store。
/// Mac 的当前项目只存在 `AppSettings.currentProject`（整个 App 一个），这里只记非项目页；iOS 的当前项目从导航路径推出（`Navigation.currentProject`）。
@Observable
final class Workspace {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: Dotted
        var isError: Bool
        /// 会话状态的提示（前台横幅）带的状态图形（`PiStateGlyph`）；nil 时按成功/错误用默认的。
        var status: PiShown.Status?
        /// 点提示去哪（如随手记的落点）；nil 时提示只是告知。
        var link: Route?
        /// 提示右边的一个动作：多是"撤销"（把刚才那一下拨回去），完成任务后是"归档"。
        var action: NoticeAction?
    }

    struct NoticeAction: Equatable {
        let id = UUID()
        let title: String
        /// 撤销刚才那一下（Mac 上 ⌘Z 也能点它）。
        var isUndo = false
        let run: Undo
        static func undo(_ run: @escaping Undo) -> Self { Self(title: "撤销", isUndo: true, run: run) }
        static func == (lhs: NoticeAction, rhs: NoticeAction) -> Bool { lhs.id == rhs.id }
    }

    let services: AppServices
    /// Cue 的现状与 Cue 页的草稿（`CueWatch`，`follow` 跟着）。
    let cue: CueWatch
    /// 本窗口的项目目录（建工作区时当场读到，`follow` 接着订阅）；nil 表示读取失败。
    private(set) var catalog: ProjectCatalog?
    /// 资料库读得出来（项目目录读到了）。读取失败时，凡是会写资料库的入口都不出现或不可用。
    var isLibraryReady: Bool { catalog != nil }
    /// 项目目录读取失败的原因；根视图据此显示错误与"重试"。
    private(set) var catalogFailure: String?
    /// 第几次读项目目录：`retryCatalog` 加一并当场重读，`follow` 就从读到的那份重新订阅。
    private(set) var catalogAttempt = 0
    /// 当场读到的那份目录（`catalogFailure` 时为 nil）：订阅从它接着走。
    @ObservationIgnored private var catalogStart: Snapshot<ProjectCatalog>?
    #if os(macOS)
    let pages = MacPages()
    let presses = CardPresses()
    let sendState: SendState
    private(set) var nonProjectPage: Route?
    /// 打开的卡（编辑页；iOS 打开卡片是推入导航，见 `Navigation.push`）。设成某张卡时编辑页立即挂上；
    /// 清空时编辑页先淡出，淡完才卸下（见 `presentedCard`）。
    var openCard: UUID? {
        didSet { if let openCard { presses.present(openCard) } }
    }
    /// 浮窗里看着的任务（`TaskSheet`）：盖在当前页上，不换页。
    var openTask: TaskSheet.Request?
    #endif
    #if os(macOS)
    /// 新建或编辑项目的表单（`ProjectForm`；侧栏与项目页的入口都经这里，主窗口弹出）。
    var projectForm: ProjectForm.Request?
    /// ⌘K 搜索开着（`SearchPalette`）。
    var searching = false
    /// 右上角的任务面板开着（`TasksPanel`）。
    var showsTasks = false
    /// 接入 Agent 的面板（`AgentSetupPanel`；首次打开由 `offerAgentSetup` 置起，主窗口弹出）。
    var showsAgentSetup = false
    #endif
    var notice: Notice?
    /// 正在给哪个项目选文件夹（iOS：根视图据此弹候选；Mac 直接弹系统的选文件夹面板，不经这里）。
    var folderPicker: Project?

    /// 交给了会话的灵感与任务（`AgentLinks`，卡与行上的状态点读它）、文件夹绑定引导（`FolderGuide`）：整个窗口一份，页面直接读，
    /// 不各自订阅（挂着的页也不会在每次回到前台时重读一遍）。读到和已有的相同就不写，免得页面白算。
    private(set) var agentLinks = AgentLinks(items: [:], launching: [])
    private(set) var folderGuide: FolderGuide?

    private func follow<T: Sendable & Equatable>(
        _ value: ReferenceWritableKeyPath<Workspace, T>, _ read: @escaping @Sendable (isolated CueStore) throws -> T
    ) async {
        do {
            for try await next in services.store.observe(read) where next != self[keyPath: value] { self[keyPath: value] = next }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    #if os(macOS)
    /// 请底部输入栏聚焦的次数（空态的"记一条"）：输入栏的焦点在它自己那里，只看这个数变了就聚焦。
    private(set) var captureFocusRequests = 0
    func focusCapture() { captureFocusRequests += 1 }
    /// 会话页放在窗口工具栏上的标题与菜单（`SessionHeader`）。
    let sessionHeader = SessionHeader()

    #endif

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// 项目目录与 Cue 的现状当场读（`CueStore.snapshot`）：第一帧就是读到的样子，没有"还没读到"这一态。
    init(services: AppServices) {
        self.services = services
        let digest = try? services.store.snapshot { try CueWatch.Reading.read(from: $0) }
        // 读不出来时目录也读不出来，失败页盖住页面，空摘要不会露面
        cue = CueWatch(digest, at: services.speech)
        #if os(macOS)
        sendState = SendState(services: services)
        #endif
        readCatalog()
    }

    #if os(macOS)
    var page: Route {
        if let nonProjectPage { return nonProjectPage }
        return (services.settings.currentProject ?? defaultProject).map(Route.project) ?? .unfiled
    }

    /// 没打开过项目（第一次打开、打开过的进了回收站）时首屏是项目目录顺序的第一个：由目录当场推出、不写进"上次打开"，
    /// 项目陆续同步进来时跟着目录走；只有用户切换项目才记下（`show`）。
    private var defaultProject: UUID? { catalog?.projects.first?.id }

    /// 当前项目（未分类为 nil）。回收站页没有项目。
    var currentProject: UUID? {
        if case .project(let id) = page { id } else { nil }
    }

    /// 此刻挂着的页：留着的加上当前页（首屏、目录纠正出来的页还没经过 `show`；会话页只在是当前页时在里面）。
    var mountedPages: [Route] { pages.kept.contains(page) ? pages.kept : pages.kept + [page] }

    /// 这一条归档或删掉了：开着它的编辑页或任务浮窗收起。
    private func closeIfOpen(_ id: UUID) {
        if openCard == id { openCard = nil }
        if openTask?.id == id { openTask = nil }
    }

    /// 编辑页淡出结束。
    func finishClosingCard() {
        guard openCard == nil else { return }
        presses.dismiss()
    }

    /// 打开一条灵感或任务：任务在浮窗里看（盖在当前页上，右上角的任务面板留着；步骤是它上级的浮窗、选中这一步）；
    /// 灵感（挂在任务下的资料也一样）进整页的编辑页。
    func open(_ card: Card) {
        presses.clearSelection()
        if card.isTask { return openTask = card.parentID.map { .init(id: $0, step: card.id) } ?? .init(id: card.id) }
        openTask = nil
        showsTasks = false
        openCard = card.id
    }

    /// 切到一页（侧栏点哪就是哪）；开着的编辑页与任务浮窗随之收起。没有历史，也没有上一层：Mac 的导航都在侧栏。
    func show(_ page: Route) {
        openCard = nil
        openTask = nil
        presses.clearSelection()
        presses.dismiss()
        pages.visit(from: self.page, to: page)
        // 打开了这个会话：它那一组通知撤掉（点通知进来的也走这里）
        if case .session(let route) = page, let alerts = services.alerts { Task { await alerts.dismiss(session: route.id) } }
        if case .project(let id) = page {
            nonProjectPage = nil
            services.settings.currentProject = id
        } else {
            nonProjectPage = page
        }
    }
    #endif

    // MARK: 提示

    static let noticeDuration: Duration = .seconds(2.4)

    func say(
        _ text: Dotted, isError: Bool = false, status: PiShown.Status? = nil, link: Route? = nil, duration: Duration = Workspace.noticeDuration,
        action: NoticeAction? = nil
    ) {
        let notice = Notice(text: text, isError: isError, status: status, link: link, action: action)
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

    /// 工作区的全部订阅，直到所在任务取消：项目目录（读不出来时按"重试"重新订阅）、交给了会话的卡、文件夹引导、Cue 的现状，
    /// Mac 上还有会话归属的项目；会话摘要由 App 级的 `LiveSessions` 跟。页面只读这里存下的那几项，不各自订阅。
    /// Mac 的工作区随 App 常驻、主窗口与两个面板共用一个，由 App 启动时跟：不挂在哪个视图上，窗口关上、内容摘下（`MainShellWindow`）
    /// 面板也照常更新；iOS 每个窗口一份，由窗口的根视图跟。
    func follow() async {
        async let catalog: Void = followCatalog()
        async let links: Void = followAgentLinks()
        async let guide: Void = followFolderGuide()
        async let cue: Void = followCue()
        #if os(macOS)
        await followSessionPlacement()
        #endif
        _ = await (catalog, links, guide, cue)
    }

    private func followCatalog() async {
        for await _ in Observations({ self.catalogAttempt }) { await observeCatalog() }
    }

    private func followAgentLinks() async { await follow(\.agentLinks) { try AgentLinks.read(from: $0) } }

    private func followFolderGuide() async { await follow(\.folderGuide) { [host = localHost] in try FolderGuide.read(host: host, from: $0) } }

    private func readCatalog() {
        do {
            try DebugHooks.willReadCatalog(attempt: catalogAttempt)
            let start = try services.store.snapshot { try ProjectCatalog.read(from: $0) }
            (catalogStart, catalog, catalogFailure) = (start, start.value, nil)
        } catch {
            (catalogStart, catalog, catalogFailure) = (nil, nil, error.localizedDescription)
        }
    }

    /// 从当场读到的那份接着订阅项目目录，直到所在任务取消；Mac 上开始时与项目增删时核对当前项目。
    /// 读取失败时清空目录并记下原因：资料库读不出来时不能接着显示过时的项目。
    private func observeCatalog() async {
        guard let start = catalogStart else { return }
        #if os(macOS)
        await reconcileCurrentProject()
        #endif
        do {
            for try await next in services.store.observe(from: start, { try ProjectCatalog.read(from: $0) }) {
                let membershipChanged = catalog.map { Set($0.projects.map(\.id)) != Set(next.projects.map(\.id)) } ?? true
                catalog = next
                if membershipChanged {
                    #if os(macOS)
                    pages.forget(projectsNotIn: Set(next.projects.map(\.id)))
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
        readCatalog()
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

    /// 点任务的圆圈：待办与进行中都变完成，完成的不再算做完（开始过的回到进行中）。下一个状态由 Store 在一个事务里按当前值定（`toggleDone`）：
    /// 界面手里的副本可能已过时（列表还没刷新就又点了一次）。
    /// 完成就是做完了：它（和它的步骤）绑着的会话里，绑着的事都做完了的一起结束——结束哪些只由 Store 定（`CueStore.toggleDone`，
    /// 与 Cue 的 done 同一条规则），结束请求写下就上传。
    func toggle(_ id: UUID) async throws {
        let (status, ended) = try await services.store.toggleDone(id)
        for request in ended { _ = services.uploaded(request) }
        // 做完了就给一个归档（不自动归档）
        guard status == .done else { return }
        say("已完成", action: NoticeAction(title: "归档") { try await self.archive(id) })
    }

    /// 设为任务 / 改回灵感；提示里带"撤销"。
    func setTodo(_ id: UUID, _ on: Bool) async throws {
        say(on ? "已设为任务" : "已改回灵感", action: .undo(try await services.store.settingTodo(id, on)))
    }

    /// 离开一条灵感或任务正文的编辑：先写下没保存的字，还是空白（`Card.isBlank`）的灵感就不留下——记一条是先建一条空的再编辑。
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
        closeIfOpen(id)
        #endif
        say("已归档", action: .undo { try await store.unarchive(id) })
    }

    /// 删除灵感或任务（一条，或 Mac 上批量选中的几条，一次写入）：提示里可撤销，撤销把这一批一起拨回。
    func trash(_ id: UUID) async throws { try await trash([id]) }

    func trash(_ ids: [UUID]) async throws {
        let undo = try await services.store.trashing(ids)
        #if os(macOS)
        ids.forEach(closeIfOpen)
        // 卡从墙上拿走时收不到鼠标移出：不再算停在它上面（⌘⌫ 删的是鼠标停着的那张）
        ids.forEach { presses.hover($0, inside: false) }
        #endif
        say(ids.count > 1 ? "已删除 \(ids.count) 条" : "已删除", action: .undo(undo))
    }

    /// 一键归档"最近完成"的任务。
    func archiveCompletedTasks() async throws {
        let count = try await services.store.archiveCompletedTasks()
        if count > 0 { say("已归档 \(count) 项任务") }
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
        attempt { try await work(store) }
    }
}
