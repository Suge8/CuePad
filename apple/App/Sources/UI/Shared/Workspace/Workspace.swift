import CueStore
import Foundation
import Observation
import SwiftUI

/// 一个窗口的界面状态；数据不放这里，界面直接订阅 Store。
@Observable
final class Workspace {
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var text: Dotted
        var tone: Tone
        var status: SessionShown.Status?
        var link: Route?
        var action: NoticeAction?
        var sound: Sound?

        var isError: Bool { tone == .failure }
        /// 只是报个结果的（没有钮、没有去处、不是出错）不接点按，点穿到下面。
        var takesHits: Bool { link != nil || action != nil || isError }

        enum Tone: Equatable {
            case done
            case gone
            case paused
            case failure

            var icon: Icon {
                switch self {
                case .done: .done
                // 不用对勾：对勾只表示完成与记下
                case .gone: .gone
                case .paused: .syncPaused
                case .failure: .failure
                }
            }
        }
    }

    struct NoticeAction: Equatable {
        /// 身份，也是它在系统撤销里的那一条的主人（`Workspace+Notice` 的 `remember`）。
        let token = NSObject()
        let title: String
        /// 撤的是什么（"归档"）：有它的才记进系统撤销，菜单写"撤销归档"。
        var undoes: String?
        /// 提示挂在工作区上、可能一直不收（读屏开着时）：工作区作为参数给，闭包里别去攥着它，不然两者互相攥着都放不掉。
        let run: @MainActor (Workspace) async throws -> Void
        static func undo(_ what: LocalizedStringResource, _ run: @escaping Undo) -> Self {
            Self(title: String(localized: "撤销"), undoes: String(localized: what)) { _ in try await run() }
        }
        static func == (lhs: NoticeAction, rhs: NoticeAction) -> Bool { lhs.token === rhs.token }
    }

    let services: AppServices
    /// 只保留当前布局的导航值；尺寸切换经 `setLayout` 转换，不缓存另一套去处。
    var navigation: Navigation {
        didSet { MainThreadWatch.shared.page(navigation.trail) }
    }
    var projectForm: ProjectFormRequest?
    /// 请求聚焦 Cue 的输入框，输入框接下后清掉。不用计数：从别的页过来时输入框是新建的，看不到数变过。
    var cueFocusPending = false
    let cue: CueWatch
    private(set) var catalog: ProjectCatalog?
    /// 读取失败时写资料库的入口都应隐藏或禁用。
    var isLibraryReady: Bool { catalog != nil }
    private(set) var catalogFailure: String?
    private(set) var catalogAttempt = 0
    @ObservationIgnored private var catalogStart: Snapshot<ProjectCatalog>?
    #if os(macOS)
    let pages = MacPages()
    let presses = CardPresses()
    let sendState: SendState
    #endif
    /// 宽屏盖在主区上的一页（卡片编辑、技能与规则的文件）：主区那一页留着，收起回到它（`Workspace.present`）。窄屏是推入的页。
    var overlay: Overlay? {
        didSet {
            #if os(macOS)
            if case .card(let id)? = overlay { presses.present(id) }
            #endif
        }
    }
    enum Overlay: Hashable {
        case card(UUID)
        case library(LibraryFile)

        init?(_ route: Route) {
            switch route {
            case .card(let id): self = .card(id)
            case .libraryFile(let file): self = .library(file)
            default: return nil
            }
        }

        var route: Route {
            switch self {
            case .card(let id): .card(id)
            case .library(let file): .libraryFile(file)
            }
        }
    }
    var openCard: UUID? { if case .card(let id)? = overlay { id } else { nil } }
    var openLibraryFile: LibraryFile? { if case .library(let file)? = overlay { file } else { nil } }
    func close(_ page: Overlay) { if overlay == page { overlay = nil } }
    var fileDrafts: [FileDraftKey: FileDraft] = [:]
    var openTask: TaskBubble.Request? {
        didSet { if openTask == nil, let oldValue { closedTask = (oldValue.task, .now) } }
    }
    var sessionAsk: SessionAsk?
    @ObservationIgnored var closedTask: (task: UUID, at: ContinuousClock.Instant)?
    @ObservationIgnored var press = PressPoint()
    @ObservationIgnored var apps = ExternalApps.system
    #if os(iOS)
    var moreCard: CardMoreRequest?
    #endif
    var voiceDetails: BubbleSource?
    var addsTask = false
    var confirmsEmptyTrash = false
    /// 开着的新会话输入框（`NewSessionInput`）。
    var newSession: SessionStart? {
        didSet { if let oldValue, oldValue.id != newSession?.id { settleLaunch(.form) } }
    }
    #if os(macOS)
    var searching = false
    var showsSetup = false
    var voice: VoiceCall? { services.voice.call }
    var hoveredProject: UUID?
    #else
    var menuOpen = false
    var outbox: Outbox? {
        didSet {
            guard outbox?.id != oldValue?.id else { return }
            if let oldValue { settleLaunch(oldValue.launchKey) }
            guard let outbox else { return }
            handOffDraft = ComposerDraft(attachments: [outbox])
        }
    }
    /// 放在这里而不在输入框里：交给已有会话的发出即收起，写库失败时还能放回、重新浮起。
    var handOffDraft = ComposerDraft()
    /// 计数而不是布尔：已在搜索页时再触发也要聚焦。
    var searchFocusRequests = 0
    #endif
    var projectScope: UUID?
    var scopedProject: UUID? { catalog?.project(projectScope)?.id }
    var libraryPane = LibraryPane.rules
    /// 放得下时恒为假（由 `fit` 保证）；`railDrawer` 同。
    var cueDrawer = false
    var railDrawer = false
    @ObservationIgnored var wideFits: WideMetrics.Fits?
    var cueAsking: String?
    var notice: Notice?
    var preview: PreviewOpening?
    /// 一次性：该会话的回复框聚焦后清掉。
    var replyFocus: UUID?
    var folderPicker: Project?

    private(set) var agentLinks = AgentLinks(items: [:], launching: [:])
    private(set) var library: AgentLibrary?
    #if os(macOS)
    /// 本机能开哪几家 Agent："开始"的悬停提示写新会话会用哪家、哪个模型。
    private(set) var localAgents: MacAgents?
    #endif
    @ObservationIgnored private var libraryStart: Snapshot<AgentLibrary?>?

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
    let overlayHeader = OverlayHeader()
    weak var openCardEditing: CardEditing?
    #endif

    let launching = Launching()
    @ObservationIgnored var launches: [SessionLaunching.Key: SessionLaunching] = [:]
    var unsavedBodies: [UUID: UnsavedBody] = [:]
    let imports = Imports()

    @ObservationIgnored var noticeTask: Task<Void, Never>?
    @ObservationIgnored var noticeDue = ContinuousClock.now
    /// 响过声的那一条：提示换了地方（会话条收起）是同一条，不再响一遍。
    @ObservationIgnored var soundedNotice: UUID?
    /// 窗口的系统撤销，根视图给（`followsUndo`）；没有窗口时（测试、菜单栏面板）为空，撤销只在提示上。
    @ObservationIgnored weak var undoManager: UndoManager?

    /// 目录与资料库当场读，不留“还没读到”这一态：第一帧就是读到的样子。
    init(services: AppServices) {
        self.services = services
        #if os(macOS)
        navigation = .wide(WideNavigation())
        #else
        navigation = .narrow(NarrowNavigation())
        #endif
        cue = CueWatch(services.cueFeed.latest()?.digest, at: services.speech, local: services.cueLocal)
        #if os(macOS)
        sendState = SendState(services: services)
        #endif
        MainThreadWatch.shared.page(navigation.trail)
        readCatalog()
        if let catalog { reconcileNavigation(projects: Set(catalog.projects.map(\.id))) }
        readLibrary()
    }

    #if os(macOS)
    /// 当前页要补进来：首屏、目录纠正出来的页没经过 `select`，不在 `pages.kept` 里。
    var mountedPages: [Route] { pages.kept.contains(mainRoute) ? pages.kept : pages.kept + [mainRoute] }

    func finishClosingCard() {
        guard openCard == nil else { return }
        presses.dismiss()
    }
    #endif

    /// 工作区的全部订阅，直到所在任务取消。Mac 的工作区随 App 常驻、主窗口与面板共用一个，由 App 启动时跟：不挂在视图上，窗口关上面板也照常更新；
    /// iOS 每个窗口一份，由窗口的根视图跟。
    func follow() async {
        async let catalog: Void = followCatalog()
        async let links: Void = followAgentLinks()
        async let launches: Void = followUnresolvedLaunches()
        async let cue: Void = followCue()
        async let opens: Void = openLinks()
        async let library: Void = followLibrary()
        async let quota: Void = followFilesQuota()
        async let cards: Void = followShownCards()
        async let files: Void = leaveGoneFiles()
        #if os(macOS)
        async let agents: Void = followLocalAgents()
        await followSessionPlacement()
        await agents
        #endif
        _ = await (catalog, links, launches, cue, opens, library, quota, cards, files)
    }

    private func followFilesQuota() async {
        var was = false
        for await over in Observations({ self.services.syncing.state.filesOverQuota }) {
            if over, !was { say(Dotted(FileStatus.overQuota), tone: .paused) }
            was = over
        }
    }

    private func followCatalog() async {
        for await _ in Observations({ self.catalogAttempt }) { await observeCatalog() }
    }

    #if os(macOS)
    private func followLocalAgents() async { await follow(\.localAgents) { [host = services.hostID] in try $0.macAgents(on: host) } }
    #endif

    private func followAgentLinks() async { await follow(\.agentLinks) { try AgentLinks.read(from: $0) } }

    private func readLibrary() {
        let host = localHost
        do {
            libraryStart = try services.store.snapshot { try $0.agentLibrary(host: host) }
            library = libraryStart?.value ?? nil
        } catch {
            fail(error)
        }
    }

    private func followLibrary() async {
        let host = localHost
        let read: @Sendable (isolated CueStore) throws -> AgentLibrary? = { try $0.agentLibrary(host: host) }
        guard let start = libraryStart else { return await follow(\.library, read) }
        do {
            for try await next in services.store.observe(from: start, read) { library = next }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    private func readCatalog() {
        do {
            try DebugHooks.willReadCatalog(attempt: catalogAttempt)
            let start = try services.store.snapshot { try ProjectCatalog.read(from: $0) }
            (catalogStart, catalog, catalogFailure) = (start, start.value, nil)
        } catch {
            (catalogStart, catalog, catalogFailure) = (nil, nil, error.localizedDescription)
        }
    }

    /// 读取失败时清空目录并记下原因：资料库读不出来时不能接着显示过时的项目。
    private func observeCatalog() async {
        guard let start = catalogStart else { return }
        reconcileNavigation(projects: Set(start.value.projects.map(\.id)))
        do {
            for try await next in services.store.observe(from: start, { try ProjectCatalog.read(from: $0) }) {
                let membershipChanged = catalog.map { Set($0.projects.map(\.id)) != Set(next.projects.map(\.id)) } ?? true
                catalog = next
                if membershipChanged { reconcileNavigation(projects: Set(next.projects.map(\.id))) }
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
        readLibrary()
    }

    func reconcileCurrentProject() async {
        do {
            reconcileNavigation(projects: Set(try await services.store.projects().map(\.id)))
        } catch {
            fail(error)
        }
    }

    private func reconcileNavigation(projects ids: Set<UUID>) {
        let settings = services.settings
        if let saved = settings.currentProject, !ids.contains(saved) { settings.currentProject = nil }
        for case .project(let id) in shownRoutes where !ids.contains(id) { leave(.project(id)) }
        #if os(macOS)
        pages.forget(projectsNotIn: ids)
        #endif
    }

    /// 看着的东西没了就离开（`leave`），由这里发现，页面不各自盯：项目看目录，卡（编辑页与开着的任务气泡）看它本身，文件看技能与规则的快照。
    private var shownRoutes: [Route] {
        let routes: [Route] = switch navigation {
        case .narrow(let state): state.path
        case .wide: [mainRoute]
        }
        return routes + [overlay?.route].compactMap(\.self)
    }

    private var shownCards: Set<UUID> {
        Set(shownRoutes.compactMap { if case .card(let id) = $0 { id } else { nil } } + [openTask?.task].compactMap(\.self))
    }

    /// 进了回收站、并进了别的卡（行被删）都算没了；看着的卡一换就换一份订阅。
    private func followShownCards() async {
        var watching: Task<Void, Never>?
        var watched: Set<UUID> = []
        defer { watching?.cancel() }
        // 气泡里翻子任务也算一次变化：同一组卡不重订
        for await ids in Observations({ self.shownCards }) where ids != watched {
            watched = ids
            watching?.cancel()
            watching = ids.isEmpty ? nil : Task { await self.leaveWhenGone(ids) }
        }
    }

    private func leaveWhenGone(_ ids: Set<UUID>) async {
        do {
            for try await live in services.store.observe({ store in try ids.filter { try store.card($0).map { $0.deletedAt == nil } ?? false } }) {
                for id in ids.subtracting(live) { leave(.card(id)) }
            }
        } catch is CancellationError {
        } catch {
            fail(error)
        }
    }

    private func leaveGoneFiles() async {
        for await gone in Observations({ self.goneFiles }) {
            for file in gone { leave(.libraryFile(file)) }
        }
    }

    /// 快照还没读到（nil）时不算没了。
    private var goneFiles: [LibraryFile] {
        guard let library else { return [] }
        return shownRoutes.compactMap { if case .libraryFile(let file) = $0, library.file(file) == nil { file } else { nil } }
    }
}
