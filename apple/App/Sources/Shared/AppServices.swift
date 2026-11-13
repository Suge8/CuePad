import Foundation
import Observation
import CueStore
import CueSync
import os
#if os(macOS)
import AppKit
import CueBridge
#else
import UIKit
#endif

/// 界面读数据直接 `store.observe(...)`；一切副作用只经这里，发送记录也只在这里写。
@Observable
final class AppServices {
    static let version: String = {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?")（\(info?["CFBundleVersion"] as? String ?? "?")）"
    }()
    nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "services")

    let store: CueStore
    #if os(macOS)
    let bridge: Bridge
    let cue: CueService
    #endif

    let settings: AppSettings
    private(set) var startupIssues: [StartupIssue] = []

    @ObservationIgnored let location: LibraryLocation
    let diagnostics: Diagnostics

    /// 没有默认值：入口必须写明，不能悄悄没有同步。
    enum SyncSource {
        case iCloud
        case custom(any SyncControlling)
        /// 用本机的库建同步：真实的同步代码连替身 iCloud，给测试与调试画面。
        case built((CueStore) -> any SyncControlling)
    }

    @ObservationIgnored let sync: (any SyncControlling)?
    @ObservationIgnored let relay: Relay?
    @ObservationIgnored let sendOrder = SendOrder()
    @ObservationIgnored lazy var voice = VoiceService(services: self, signaling: relay)
    private(set) var syncState: SyncState
    /// key 离开就是那一趟结束了；文件在不在本机看附件目录。
    private(set) var fileTransfers: [String: FileTransfer] = [:]
    #if os(iOS)
    /// 每个窗口自己决定弹不弹。
    private(set) var sessionAlert: SessionAlert?
    #endif
    let speechClock: SpeechClock
    /// 资料库里随时间变的读、说的话到点翻状态、主动拉取的节奏共用这一个钟。
    @ObservationIgnored let timing: Timing
    /// 界面与服务都从这里取，不各自订阅。
    let liveSessions: LiveSessions
    let cueFeed: CueFeed
    let accountQuotas = AccountQuotas()
    private(set) var conflicts: [CardConflict] = []

    /// 待打开的页：写入后由工作区取走（`Workspace.openLinks`）。
    var pendingDeepLink: DeepLink?

    @ObservationIgnored let tasks = Followers()
    /// iOS 整个进后台时取消、回前台再开。
    @ObservationIgnored var polling: Task<Void, Never>?
    var hasOpenDeliveries = false
    var sessionViewers = 0
    /// 只由 `CueViewing` 增减；算不算在看的规则在它那里。
    var cueViewers = 0
    #if os(macOS)
    /// 按窗口是否露在屏上定，有没有焦点都算。
    var mainWindowExposed = true
    var away = false
    /// 会话页、Cue 页的在场、读过与提示都只认它。
    var seesMainWindow: Bool { mainWindowExposed && !away }
    #endif
    /// 还没返回的立即同步有几个（`syncNow`）。
    var syncNowWaits = 0
    @ObservationIgnored var syncConnected = false
    var isSyncingNow: Bool { syncNowWaits > 0 }
    @ObservationIgnored let flights = Flights()
    @ObservationIgnored var publishedSnapshots: WidgetSnapshots?
    /// 这台设备开着哪一页的唯一写入口。
    @ObservationIgnored let viewer: ViewerKeeper?
    @ObservationIgnored var backgroundFlushes: [UUID: @MainActor () async -> Void] = [:]

    /// App 代理持有的那一个，`start()` 前接上；测试没有，不发真实通知。
    @ObservationIgnored weak var alerts: AlertCenter?

    #if os(iOS)
    @ObservationIgnored let pasteboard: UIPasteboard
    /// 隔离实例默认不开，避免遗留活动唤醒测试宿主；验收用 `-CuePadLiveActivity YES`。
    @ObservationIgnored private(set) var cueActivity: CueLiveActivity?
    #endif

    #if os(macOS)
    let agents: AgentIntegrations
    let commandLineTool: CommandLineToolInstaller
    let updates: UpdateService
    @ObservationIgnored var windowShell: MainShellWindow?

    @ObservationIgnored let paths: AgentPaths
    @ObservationIgnored let runtimes: [AgentKind: any AgentRuntime]
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored let historyStore: HistoryPersistence
    @ObservationIgnored let hotkeyBackend: any HotkeyBackend
    @ObservationIgnored var hotkeys: [GlobalHotkey] = []
    @ObservationIgnored let hostID: String
    @ObservationIgnored let workspaces: Workspaces
    @ObservationIgnored let wakeNotifications: NotificationCenter
    @ObservationIgnored let stateRecorder: StateRecorder
    @ObservationIgnored let presence: MacPresenceKeeper
    /// 同步表 `macAgents` 的唯一写入口；Cue 启用前也经它问。
    @ObservationIgnored let macAgents: MacAgentsRecorder
    /// 同步表 `agentLibraries` 的唯一写入口，整理与改规则也经它。
    @ObservationIgnored let library: AgentLibraryKeeper
    @ObservationIgnored lazy var executor = MacExecutor(
        store: store, bridge: bridge, runtimes: runtimes, hostID: hostID, workspaces: workspaces, recorder: stateRecorder, library: library,
        upload: { [weak self] id in await self?.upload(id) },
        fetchFile: { [sync] key in try await sync.fetchFile(key) },
        refreshQuota: { [weak self] in await self?.refreshQuota(.manual) },
        reportIssue: { [weak self] message in self?.reportIssue(.syncUnavailable(message)) })

    @ObservationIgnored lazy var hotkey = GlobalHotkey(
        label: String(localized: "显示或隐藏 CuePad"), key: AppSettings.Key.globalShortcut, defaultAccelerator: "Alt+Shift+Space", defaults: settings.defaults,
        backend: hotkeyBackend
    ) { [weak self] in self?.windowShell?.toggleFromHotkey() }
    #endif

    nonisolated enum StartupIssue: Equatable {
        case globalShortcutUnavailable(String)
        /// 分享扩展留下的内容没能入库（保留在共享容器里，下次再试）。
        case captureImportFailed(String)
        /// 跟着库常驻的本机功能没能启动或停了：是哪一项写在原因里。
        case syncUnavailable(String)
        case widgetDataUnavailable(String)
        #if os(macOS)
        case bridgeUnavailable(String)
        /// Pi 历史索引读写 Store 失败；该会话文件不再写回。
        case historyUnavailable(String)
        #endif
    }

    // 打不开资料库时不能悄悄换一个空库，也不能带着它往下走：错误交给调用方，启动入口显示失败页（`UnreadableLibraryView`），不终止进程。
    #if os(macOS)
    init(location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, mac: MacDependencies) throws {
        let store = try CueStore(location: location, timing: mac.timing)
        try Self.launch(store, on: mac.hostID, bridge: mac.bridge)
        self.store = store
        settings = AppSettings(defaults: defaults)
        self.location = location
        diagnostics = Diagnostics(directory: location.directory.appending(path: "Diagnostics", directoryHint: .isDirectory))
        let (engine, status) = Self.makeSync(sync, store: store, location: location)
        (self.sync, syncState) = (engine, SyncState(status: status, issues: []))
        relay = Self.makeRelay(sync, engine, device: mac.hostID)
        speechClock = SpeechClock(localHost: mac.hostID, reachable: status.reachesMac, alwaysReachable: DebugHooks.preset.alwaysReachable, timing: mac.timing)
        liveSessions = try LiveSessions(store: store, endedOn: mac.hostID, at: speechClock.moment)
        cueFeed = CueFeed(store: store, widget: false)
        timing = mac.timing
        hostID = mac.hostID
        workspaces = mac.workspaces
        wakeNotifications = mac.wakeNotifications
        stateRecorder = StateRecorder(store: store, hostID: mac.hostID, timing: mac.timing)
        presence = MacPresenceKeeper(store: store, sync: self.sync, host: mac.hostID)
        viewer = ViewerKeeper(store: store, sync: self.sync, device: mac.hostID)
        bridge = mac.bridge
        pasteboard = mac.pasteboard
        hotkeyBackend = mac.hotkeys
        paths = mac.paths
        runtimes = mac.runtimes(store)
        agents = mac.agents
        macAgents = MacAgentsRecorder(store: store, sync: self.sync, host: mac.hostID, agents: agents)
        // 隔离运行时移走的不进系统废纸篓，放在库里
        let trash = location.touchesRealWorld ? nil : AgentLibraryFiles.trash(into: location.directory.appending(path: "Trash", directoryHint: .isDirectory))
        library = AgentLibraryKeeper(
            store: store, sync: self.sync, host: mac.hostID, files: AgentLibraryFiles(access: agents.integration.fileAccess, trash: trash))
        commandLineTool = mac.commandLineTool
        updates = UpdateService(updater: mac.updater, bridge: mac.bridge, runtimes: runtimes)
        historyStore = HistoryPersistence(storage: store, host: mac.hostID)
        cue = CueService(
            recorder: stateRecorder, sync: self.sync, library: location.directory,
            piAgentDirectory: mac.paths.pi.agentDirectory, dependencies: mac.cue)
    }
    #else
    init(
        location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, pasteboard: UIPasteboard = .general, timing: Timing = .system
    ) throws {
        let store = try CueStore(location: location, timing: timing)
        self.store = store
        settings = AppSettings(defaults: defaults)
        self.location = location
        diagnostics = Diagnostics(directory: location.directory.appending(path: "Diagnostics", directoryHint: .isDirectory))
        let (engine, status) = Self.makeSync(sync, store: store, location: location)
        (self.sync, syncState) = (engine, SyncState(status: status, issues: []))
        relay = Self.makeRelay(sync, engine, device: UIDevice.current.identifierForVendor?.uuidString)
        speechClock = SpeechClock(localHost: nil, reachable: status.reachesMac, alwaysReachable: DebugHooks.preset.alwaysReachable, timing: timing)
        liveSessions = try LiveSessions(store: store, endedOn: nil, at: speechClock.moment)
        cueFeed = CueFeed(store: store, widget: true)
        self.timing = timing
        self.pasteboard = pasteboard
        let activitySync: (any SyncControlling)? = if case .iCloud = sync, location.touchesRealWorld { self.sync } else { nil }
        viewer = UIDevice.current.identifierForVendor.map { [sync = self.sync] in
            ViewerKeeper(store: store, sync: sync, device: $0.uuidString)
        }
        if location.touchesRealWorld || DebugHooks.opensLiveActivity {
            cueActivity = CueLiveActivity.make(store: store, sync: activitySync, location: location) { [weak self] in
                try self?.remoteActivityState()
            }
        }
    }
    #endif

    #if os(iOS)
    func post(_ alert: SessionAlert) { sessionAlert = alert }
    #endif

    /// 读不出就照常提示，宁可多响一次也不悄悄吞掉。
    func reaches(_ subject: AlertSubject) async -> Bool {
        do {
            return try await store.reaches(subject)
        } catch {
            Self.log.error("没能读出这条提示到不到你，照常提示：\(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    /// 换账号或清除资料前先撤销活动；重置同步令牌的决定已做出，不等异步状态流才阻止旧库重开活动。
    func resolveSync(_ resolution: SyncResolution) async throws {
        #if os(iOS)
        await cueActivity?.invalidate(reason: "resolveSync").value
        #endif
        syncState.reconciled = false
        try await sync?.resolve(resolution)
    }

    /// 同步从不通变通时立即同步一次：断网时没传上去的记录当场传出、在等的回执当场拉回，不等发送者的退避。
    func setSyncState(_ state: SyncState) {
        let recovered = state.status.reachesMac && speech.reachableSince == nil
        #if os(macOS)
        if state.status == .outdated, syncState.status != .outdated { updates.checkInBackground() }
        #endif
        #if os(iOS)
        if syncState.status != state.status {
            switch state.status {
            case .noAccount: cueActivity?.invalidate(reason: "syncNoAccount")
            case .needsDecision: cueActivity?.invalidate(reason: "syncNeedsDecision")
            default: break
            }
        }
        #endif
        syncState = state
        speechClock.setReachable(state.status.reachesMac)
        if recovered { Task { await syncNow() } }
    }

    func setFileTransfers(_ transfers: [String: FileTransfer]) {
        fileTransfers = transfers
    }

    func setConflicts(_ conflicts: [CardConflict]) {
        self.conflicts = conflicts
    }

    func reportIssue(_ issue: StartupIssue) {
        Self.log.error("\(String(describing: issue))")
        startupIssues.append(issue)
    }
}
