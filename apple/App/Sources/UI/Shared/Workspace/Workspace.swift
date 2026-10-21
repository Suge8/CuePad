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
    /// 清空时编辑页先淡出，淡完才卸下（`CardEditorPage`）。
    var openCard: UUID? {
        didSet { if let openCard { presses.present(openCard) } }
    }
    #endif
    /// 气泡里看着的任务（`TaskBubble`）：从被点的那一下长出来，盖在当前页上，不换页。两端同一份，各个入口都经 `openTask(_:)`。
    var openTask: TaskBubble.Request? {
        didSet { if openTask == nil, let oldValue { closedTask = (oldValue.task, .now) } }
    }
    /// 刚收起的气泡是哪件事、什么时候：按在它那一行上收起的（按下就关，松开时那一行又要打开它），这一下不再打开。
    @ObservationIgnored var closedTask: (task: UUID, at: ContinuousClock.Instant)?
    @ObservationIgnored var press = PressPoint()
    #if os(macOS)
    /// 新建或编辑项目的表单（`ProjectForm`；侧栏与项目页的入口都经这里，主窗口弹出）。
    var projectForm: ProjectForm.Request?
    /// ⌘K 搜索开着（`SearchPalette`）。
    var searching = false
    /// 接入 Agent 并启用 Cue 的面板（`SetupPanel`；首次打开由 `offerSetup` 置起，Cue 页的启用卡与会话页的"接入"也打开它，主窗口弹出）。
    var showsSetup = false
    /// 新会话的表单开着（`NewSessionForm`，从会话页的 + 弹出；菜单"文件 › 新会话"先去会话页再置起，`newSession`）。
    var showsNewSession = false
    /// 任务页待办顶上浮出添加那一行（页上的"新任务"与右上"⋯"里的同一下）。
    var addsTask = false
    /// 清空回收站的确认开着（回收站页上与"⋯"里的"清空回收站…"同一下）。
    var confirmsEmptyTrash = false
    #endif
    /// 项目范围：任务页与会话页共用这一份（顶栏中间那颗显示它、点 ✕ 清掉；项目页"⋯"里的"看这个项目的会话"设成这个项目再切到会话页），nil 是全部项目。
    var projectScope: UUID?
    var notice: Notice?
    /// 正在给哪个项目选文件夹（iOS：根视图据此弹候选；Mac 直接弹系统的选文件夹面板，不经这里）。
    var folderPicker: Project?

    /// 交给了会话的灵感与任务（`AgentLinks`，卡与行上的状态点读它）：整个窗口一份，页面直接读，
    /// 不各自订阅（挂着的页也不会在每次回到前台时重读一遍）。读到和已有的相同不送来（`observe(after:)` 在读取一侧比较），免得页面白算。
    private(set) var agentLinks = AgentLinks(items: [:], launching: [])

    private func follow<T: Sendable & Equatable>(
        _ value: ReferenceWritableKeyPath<Workspace, T>, _ read: @escaping @Sendable (isolated CueStore) throws -> T
    ) async {
        do {
            for try await next in services.store.observe(after: self[keyPath: value], read) { self[keyPath: value] = next }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    #if os(macOS)
    /// 请底部输入栏聚焦的次数（空态的"记一条"）：输入栏的焦点在它自己那里，只看这个数变了就聚焦。
    private(set) var captureFocusRequests = 0
    func focusCapture() { captureFocusRequests += 1 }
    let sessionHeader = SessionHeader()

    #endif

    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    /// 项目目录与 Cue 的现状当场读（`CueStore.snapshot`）：第一帧就是读到的样子，没有"还没读到"这一态。
    init(services: AppServices) {
        self.services = services
        let digest = try? services.store.snapshot { try CueDigest.read(from: $0) }
        // 读不出来时目录也读不出来，失败页盖住页面，空摘要不会露面
        cue = CueWatch(digest, at: services.speech, local: services.cueLocal)
        #if os(macOS)
        sendState = SendState(services: services)
        #endif
        readCatalog()
    }

    #if os(macOS)
    /// 此刻的页：切到的非项目页，否则上次打开的项目（`show` 记下），都没有是 `Route.first`。
    var page: Route {
        if let nonProjectPage { return nonProjectPage }
        return services.settings.currentProject.map(Route.project) ?? .first
    }

    /// 当前项目；不在项目页（回收站、会话页……）时没有。
    var currentProject: UUID? {
        if case .project(let id) = page { id } else { nil }
    }

    /// 此刻挂着的页：留着的加上当前页（首屏、目录纠正出来的页还没经过 `show`；会话页只在是当前页时在里面）。
    var mountedPages: [Route] { pages.kept.contains(page) ? pages.kept : pages.kept + [page] }

    func finishClosingCard() {
        guard openCard == nil else { return }
        presses.dismiss()
    }

    /// 打开一条灵感或任务：任务在气泡里看（`openTask`）；
    /// 灵感（挂在任务下的资料也一样）进整页的编辑页。
    func open(_ card: Card) {
        presses.clearSelection()
        if card.isTask { return openTask(card) }
        openTask = nil
        openCard = card.id
    }

    /// 切到一页（侧栏点哪就是哪）；开着的编辑页与任务气泡随之收起。没有历史，也没有上一层：Mac 的导航都在侧栏。
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
        async let cue: Void = followCue()
        #if os(macOS)
        await followSessionPlacement()
        #endif
        _ = await (catalog, links, cue)
    }

    private func followCatalog() async {
        for await _ in Observations({ self.catalogAttempt }) { await observeCatalog() }
    }

    private func followAgentLinks() async { await follow(\.agentLinks) { try AgentLinks.read(from: $0) } }

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
