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

    enum SyncSource {
        case iCloud
        case custom(any SyncControlling)
        case built((CueStore) -> any SyncControlling, relay: URL? = nil)
    }

    @ObservationIgnored let sync: (any SyncControlling)?
    @ObservationIgnored let relay: Relay?
    @ObservationIgnored let sendOrder = SendOrder()
    @ObservationIgnored lazy var voice = VoiceService(services: self, signaling: relay)
    @ObservationIgnored lazy var liveSignaling: (any VoiceSignaling)? = relay
    @ObservationIgnored let liveEvents = AsyncStream<VoiceRelayEvent>.makeStream()
    #if os(iOS)
    @ObservationIgnored private(set) lazy var liveRemote = LiveRemote(store: store, settings: settings) { [weak self] in self?.liveSignaling }
    #endif
    @ObservationIgnored private(set) lazy var syncing = SyncDriver(
        engine: sync, status: syncStart, store: store, timing: timing, speechClock: speechClock, localHost: speechClock.moment.localHost, tasks: tasks,
        cadence: { [weak self] in self?.pollingCadence },
        statusChanged: { [weak self] in self?.syncStatusChanged(to: $0) },
        report: { [weak self] in self?.reportIssue($0) })
    @ObservationIgnored private let syncStart: SyncStatus
    @ObservationIgnored private(set) lazy var snapshots = SnapshotPublisher(store: store, directory: location.snapshotsDirectory) { [weak self] digest, first, resend in
        guard let self else { throw CancellationError() }
        return try await present(digest, first: first, resend: resend)
    }
    @ObservationIgnored private(set) lazy var captures = CaptureIngest(store: store, directory: location.captureDirectory) { [weak self] in self?.reportIssue($0) }
    #if os(iOS)
    private(set) var sessionAlert: SessionAlert?
    #endif
    let speechClock: SpeechClock
    @ObservationIgnored let timing: Timing
    let liveSessions: LiveSessions
    let cueFeed: CueFeed
    let accountQuotas = AccountQuotas()

    var pendingDeepLink: DeepLink?

    @ObservationIgnored let tasks: Followers
    var hasOpenDeliveries = false
    @ObservationIgnored let viewer: ViewerKeeper
    @ObservationIgnored var backgroundFlushes: [UUID: @MainActor () async -> Void] = [:]

    @ObservationIgnored weak var alerts: AlertCenter?

    #if os(iOS)
    @ObservationIgnored let pasteboard: UIPasteboard
    @ObservationIgnored let device: String?
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
    @ObservationIgnored let deviceLogs: URL
    @ObservationIgnored let wakeNotifications: NotificationCenter
    @ObservationIgnored let stateRecorder: StateRecorder
    @ObservationIgnored let presence: MacPresenceKeeper
    @ObservationIgnored let macAgents: MacAgentsRecorder
    @ObservationIgnored let library: AgentLibraryFiles
    @ObservationIgnored lazy var executor = MacExecutor(
        store: store, bridge: bridge, runtimes: runtimes, hostID: hostID, workspaces: workspaces, recorder: stateRecorder, library: library,
        fetchFile: { [sync] key in try await sync.fetchFile(key) },
        refreshQuota: { [weak self] in await self?.refreshQuota(.manual) },
        reportIssue: { [weak self] message in self?.reportIssue(.syncUnavailable(message)) })

    @ObservationIgnored lazy var hotkey = GlobalHotkey(
        label: String(localized: "显示或隐藏 CuePad"), slot: .main, settings: settings, backend: hotkeyBackend
    ) { [weak self] in self?.windowShell?.toggleFromHotkey() }
    #endif

    nonisolated enum StartupIssue: Equatable {
        case globalShortcutUnavailable(String)
        case captureImportFailed(String)
        case captureUnreadable(String)
        case syncUnavailable(String)
        case widgetDataUnavailable(String)
        #if os(macOS)
        case bridgeUnavailable(String)
        case historyUnavailable(String)
        #endif
    }

    #if os(macOS)
    init(location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, mac: MacDependencies) throws {
        let store = try CueStore(location: location, timing: mac.timing)
        try Self.launch(store, on: mac.hostID, bridge: mac.bridge)
        self.store = store
        settings = AppSettings(defaults: defaults)
        self.location = location
        diagnostics = Diagnostics(directory: location.directory.appending(path: "Diagnostics", directoryHint: .isDirectory))
        let (engine, status) = Self.makeSync(sync, store: store, location: location)
        self.sync = engine
        relay = Self.makeRelay(sync, engine, device: mac.hostID)
        speechClock = SpeechClock(localHost: mac.hostID, reachable: status.reachesMac, alwaysReachable: DebugHooks.preset.alwaysReachable, timing: mac.timing)
        let tasks = Followers()
        self.tasks = tasks
        syncStart = status
        liveSessions = try LiveSessions(store: store, endedOn: mac.hostID, at: speechClock.moment)
        cueFeed = CueFeed(store: store, widget: false)
        timing = mac.timing
        hostID = mac.hostID
        workspaces = mac.workspaces
        deviceLogs = try location.deviceLogs()
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
        macAgents = MacAgentsRecorder(store: store, host: mac.hostID, agents: agents)
        let trash = location.touchesRealWorld ? nil : AgentLibraryFiles.trash(into: location.directory.appending(path: "Trash", directoryHint: .isDirectory))
        library = AgentLibraryFiles(store: store, host: mac.hostID, access: agents.integration.fileAccess, trash: trash)
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
        self.sync = engine
        let device = UIDevice.current.identifierForVendor?.uuidString
        self.device = device
        relay = Self.makeRelay(sync, engine, device: device)
        speechClock = SpeechClock(localHost: nil, reachable: status.reachesMac, alwaysReachable: DebugHooks.preset.alwaysReachable, timing: timing)
        let tasks = Followers()
        self.tasks = tasks
        syncStart = status
        liveSessions = try LiveSessions(store: store, endedOn: nil, at: speechClock.moment)
        cueFeed = CueFeed(store: store, widget: true)
        self.timing = timing
        self.pasteboard = pasteboard
        let activitySync: (any SyncControlling)? = if case .iCloud = sync, location.touchesRealWorld { self.sync } else { nil }
        viewer = ViewerKeeper(store: store, sync: self.sync, device: device)
        if location.touchesRealWorld || DebugHooks.opensLiveActivity {
            cueActivity = CueLiveActivity(store: store, sync: activitySync, device: device, diagnostics: diagnostics) { [weak self] in
                guard let self else { return nil }
                return try self.activityState(try self.store.snapshot { try CueDigest.read(from: $0) }.value)
            }
        }
    }
    #endif

    #if os(iOS)
    func post(_ alert: SessionAlert) { sessionAlert = alert }
    #endif

    func reaches(_ subject: AlertSubject) async -> Bool {
        do {
            return try await store.reaches(subject)
        } catch {
            Self.log.error("没能读出这条提示到不到你，照常提示：\(error.localizedDescription, privacy: .public)")
            return true
        }
    }

    func resolveSync(_ resolution: SyncResolution) async throws {
        #if os(iOS)
        await cueActivity?.invalidate(reason: "resolveSync").value
        #endif
        try await syncing.resolve(resolution)
    }

    func reportIssue(_ issue: StartupIssue) {
        Self.log.error("\(String(describing: issue))")
        startupIssues.append(issue)
    }
}
