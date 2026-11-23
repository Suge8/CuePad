import CueStore
import Foundation
import Observation
import SwiftUI

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
        var takesHits: Bool { link != nil || action != nil || isError }

        enum Tone: Equatable {
            case done
            case gone
            case paused
            case failure
            case pick

            var icon: Icon {
                switch self {
                case .done: .done
                case .pick: .session
                case .gone: .gone
                case .paused: .syncPaused
                case .failure: .failure
                }
            }
        }
    }

    struct NoticeAction: Equatable {
        let token = NSObject()
        let title: String
        var undoes: String?
        let run: @MainActor (Workspace) async throws -> Void
        static func undo(_ what: LocalizedStringResource, _ run: @escaping Undo) -> Self {
            Self(title: String(localized: "撤销"), undoes: String(localized: what)) { _ in try await run() }
        }
        static func == (lhs: NoticeAction, rhs: NoticeAction) -> Bool { lhs.token === rhs.token }
    }

    let services: AppServices
    var navigation: Navigation {
        didSet {
            MainThreadWatch.shared.page(navigation.trail)
            if case .wide(let now) = navigation, case .wide(let was) = oldValue { settle(from: was, to: now) }
            #if os(iOS)
            keepLivePreviews()
            #endif
            if let liveFill, !showsLivePreview(liveFill.session) { endLiveFill() }
        }
    }
    /// 宽屏变窄那一下的样子：窄屏装不下一排里的全部（页与会话同屏、几条灵感、活预览），原样变回宽屏时照它摆回去；窄屏上动过导航就不认了。
    @ObservationIgnored var widened: (narrow: NarrowNavigation, wide: WideNavigation, overlay: Overlay?)?
    var projectForm: ProjectFormRequest?
    var cueFocusPending = false
    let cue: CueWatch
    private(set) var catalog: ProjectCatalog?
    var isLibraryReady: Bool { catalog != nil }
    private(set) var catalogFailure: String?
    private(set) var catalogAttempt = 0
    @ObservationIgnored private var catalogStart: Snapshot<ProjectCatalog>?
    #if os(macOS)
    let pages = MacPages()
    let presses = CardPresses()
    let sendState: SendState
    #endif
    /// 宽屏盖在页那一块上的（点开的灵感、规则文件；页不在这一排时盖在最左那块上）。底下那块换了、这条灵感自己成了一块，就收（`settle`）。
    var overlay: Overlay? {
        didSet {
            #if os(macOS)
            if case .card(let id)? = overlay { presses.present(id) }
            #endif
        }
    }

    /// 新进这一排的会话，它的回复框摆出来时接过焦点（`settle` 定，那个回复框摆出来时取走）。只在 Mac：触屏上不替人弹键盘。
    /// 页不自己一摆出来就拿：启动时几页一起摆出来、答完题输入框重新出来，都会从别处把焦点拿走。
    @ObservationIgnored private var replyLanding: UUID?
    /// 刚从这一排右头走掉的块（它右边没有留下来的）：滑出去之前照旧画着（`PaneRow`），滑完撤掉。别处走掉的当场就没了，旁边的块滑过来补上。
    private(set) var leaving: [WideNavigation.Pane] = []
    @ObservationIgnored private var leavingDone: Task<Void, Never>?

    private func settle(from was: WideNavigation, to now: WideNavigation) {
        #if os(macOS)
        if let opened = now.sessions.first(where: { opened in !was.sessions.contains { $0.id == opened.id } }) { replyLanding = opened.id }
        #endif
        leave(was.panes.dropFirst(now.panes.count).reversed().prefix { $0.page == nil && !now.panes.contains($0) })
        let moved = was.panes[was.host] != now.panes[now.host]
        if moved || openCard.map({ now.panes.contains(.card($0)) }) == true { overlay = nil }
        #if os(macOS)
        guard moved else { return }
        presses.clearSelection()
        presses.dismiss()
        pages.visit(from: was.page, to: now.page)
        #endif
    }

    private func leave(_ panes: some Collection<WideNavigation.Pane>) {
        guard !panes.isEmpty else { return }
        leaving = leaving.filter { !panes.contains($0) } + panes
        leavingDone?.cancel()
        leavingDone = Task {
            guard (try? await Task.sleep(for: WideSlide.duration)) != nil else { return }
            leaving = []
        }
    }

    func takeReplyLanding(_ session: UUID) -> Bool {
        guard replyLanding == session else { return false }
        replyLanding = nil
        return true
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
    var answering = 0
    var dropDeclines = 0
    @ObservationIgnored var completionClaims: [UUID: [UUID]] = [:]
    @ObservationIgnored var closedTask: (task: UUID, at: ContinuousClock.Instant)?
    @ObservationIgnored var press = PressPoint()
    @ObservationIgnored var apps = ExternalApps.system
    #if os(iOS)
    var moreCard: CardMoreRequest?
    #endif
    var voiceDetails: BubbleSource?
    var confirmsEmptyTrash = false
    var newTask: TaskStart?
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
    var handOffDraft = ComposerDraft()
    var searchFocusRequests = 0
    #endif
    var projectScope: UUID?
    var scopedProject: UUID? { catalog?.project(projectScope)?.id }
    var libraryPane = LibraryPane.rules
    var cueDrawer = false
    var railDrawer = false
    @ObservationIgnored var wideFits: WideMetrics.Fits?
    var notice: Notice? {
        didSet { if oldValue?.tone == .pick, notice?.tone != .pick, pickingDock { setDock(nil) } }
    }
    var preview: PreviewOpening?
    var dropTarget: WideDropTarget?
    @ObservationIgnored var dragging: WideNavigation.Pane??
    var replyFocus: UUID?
    var folderPicker: Project?

    private(set) var agentLinks = AgentLinks(items: [:], launching: [:])
    private(set) var library: AgentLibrary?
    #if os(macOS)
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

    var livePreviews: [UUID: LivePreview] = [:]
    var liveFill: LiveFill?
    #if os(iOS)
    var liveCover: UUID?
    #endif
    #if os(macOS)
    var liveSent: [UUID: LivePreview.Target] = [:]
    var liveFound: [UUID: [URL]] = [:]
    @ObservationIgnored var liveScanner = LiveServers()
    @ObservationIgnored var liveScanning: Task<Void, Never>?
    @ObservationIgnored var liveTaken: [String: LiveAddress] = [:]
    @ObservationIgnored var liveTurns: [UUID: Task<LiveChannel.Reply, Never>] = [:]
    @ObservationIgnored var liveReleased: Set<UUID> = []
    var livePhones: [LivePhone.Key: LivePhone] = [:]
    @ObservationIgnored var liveServer: (server: LiveTunnel.Server, port: UInt16)?
    @ObservationIgnored var liveServerStarting: Task<UInt16?, Never>?
    @ObservationIgnored var livePorts: [String: (ports: [Int: String], at: ContinuousClock.Instant)] = [:]
    #endif
    var paneShares = WideMetrics.Shares()

    let launching = Launching()
    @ObservationIgnored var launches: [SessionLaunching.Key: SessionLaunching] = [:]
    var unsavedBodies: [UUID: UnsavedBody] = [:]
    let imports = Imports()

    @ObservationIgnored var noticeTask: Task<Void, Never>?
    @ObservationIgnored var noticeDue = ContinuousClock.now
    @ObservationIgnored var soundedNotice: UUID?
    @ObservationIgnored weak var undoManager: UndoManager?

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
    var mountedPages: [Route] {
        guard let page = pageRoute, !pages.kept.contains(page) else { return pages.kept }
        return pages.kept + [page]
    }

    func finishClosingCard() {
        guard openCard == nil else { return }
        presses.dismiss()
    }
    #endif

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
        #if os(iOS)
        async let returns: Void = followReturns()
        #endif
        #if os(macOS)
        async let agents: Void = followLocalAgents()
        async let live: Void = followLiveAddresses()
        async let liveAgent: Void = serveLiveAgent()
        async let liveScan: Void = watchLiveServers()
        async let livePhones: Void = followLivePhones()
        await followSessionPlacement()
        _ = await (agents, live, liveAgent, liveScan, livePhones)
        #endif
        #if os(iOS)
        await returns
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

    private var shownRoutes: [Route] {
        let routes: [Route] = switch navigation {
        case .narrow(let state): state.path
        case .wide(let state): state.panes.compactMap(\.route)
        }
        return routes + [overlay?.route].compactMap(\.self)
    }

    private var shownCards: Set<UUID> {
        Set(shownRoutes.compactMap { if case .card(let id) = $0 { id } else { nil } } + [openTask?.task].compactMap(\.self))
    }

    private func followShownCards() async {
        var watching: Task<Void, Never>?
        var watched: Set<UUID> = []
        defer { watching?.cancel() }
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

    private var goneFiles: [LibraryFile] {
        guard let library else { return [] }
        return shownRoutes.compactMap { if case .libraryFile(let file) = $0, library.file(file) == nil { file } else { nil } }
    }
}
