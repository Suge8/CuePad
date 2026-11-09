import Foundation
import Observation
import CueStore
import CueSync
import os
#if os(macOS)
import AppKit
import CuePi
#else
import UIKit
#endif

/// 组合根与界面动作的唯一入口：持有各模块的唯一实例。
/// 界面读数据直接 `store.observe(...)`；一切副作用（发给 Agent、复制、Pi 命令、终端跳转、导入、扩展安装）只经这里，
/// 发送记录也只在这里写。
@Observable
final class AppServices {
    static let version: String = {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?")（\(info?["CFBundleVersion"] as? String ?? "?")）"
    }()
    nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "services")

    let store: CueStore
    #if os(macOS)
    let pi: PiBridge
    let cue: CueService
    #endif

    let settings: AppSettings
    /// 启动期间没能完成的事；界面据此提示，不静默。
    private(set) var startupIssues: [StartupIssue] = []

    @ObservationIgnored let location: LibraryLocation
    let diagnostics: Diagnostics

    /// iCloud 同步从哪来：正式启动按位置与本构建的 iCloud 权限决定（`makeSync`），测试注入替身。
    /// 没有默认值：入口必须写明，不能悄悄没有同步。
    enum SyncSource {
        case iCloud
        case custom(any SyncControlling)
        /// 用本机的库建的同步：真实的同步代码连替身 iCloud（`CloudSync` 的替身连接），给测试与调试画面。
        case built((CueStore) -> any SyncControlling)
    }

    /// iCloud 同步；没有时同步状态是写明原因的 `.unavailable`。
    @ObservationIgnored let sync: (any SyncControlling)?
    /// 门铃（实时层，见 `AppServices+Relay`）；不连真的 iCloud（替身、没有 iCloud 权限、隔离库）时没有。
    @ObservationIgnored let relay: Relay?
    @ObservationIgnored let sendOrder = SendOrder()
    @ObservationIgnored lazy var voice = VoiceService(services: self, signaling: relay)
    /// 同步此刻的样子（`sync.stateUpdates` 送来的那一份，`setSyncState` 写）：状态、问题、积压、对过没有、文件空间、锁屏通知的订阅都只读这里。
    private(set) var syncState: SyncState
    /// 附件文件此刻在路上的，按 key（`CloudSync.fileTransfers`）：附件那一格据此画进度；key 离开就是那一趟结束了，文件在不在本机看附件目录。
    private(set) var fileTransfers: [String: FileTransfer] = [:]
    #if os(iOS)
    /// 最近一次要在前台提示的会话转换；每个窗口自己决定弹不弹。
    private(set) var sessionAlert: SessionAlert?
    #endif
    /// 说的话到哪了的"此刻"与同步通着的起点，整个 App 一份（`start()` 开始跟着库）。
    let speechClock: SpeechClock
    /// App 的钟：资料库里随时间变的读（`CueStore.timing`）、说的话到点翻状态（`SpeechClock`）与主动拉取的节奏（`SyncPoller`）共用一个。
    @ObservationIgnored let timing: Timing
    /// 此刻有事的 Pi 会话，整个 App 一份（打开资料库时当场读到第一份，`start()` 接着跟随）：界面与服务都从这里取，不各自订阅。
    let liveSessions: LiveSessions
    /// Cue 的现状，整个 App 一份：Cue 那一行与 iPhone 的小组件快照都从这里取（`cueUpdates`）。
    let cueFeed: CueFeed
    let accountQuotas = AccountQuotas()
    /// 待用户处理的正文冲突（同一张卡离线并发编辑产生的副本）。
    private(set) var conflicts: [CardConflict] = []

    /// 小组件、分享扩展、实时活动的链接与点开的通知要打开的页（`handle(url:)`、`AlertCenter.receive`），工作区取走（`Workspace.openLinks`）。
    var pendingDeepLink: DeepLink?

    @ObservationIgnored let tasks = Followers()
    /// 有理由等就拉的任务（见 `startPolling`）；iOS 整个进后台时取消、回前台再开。
    @ObservationIgnored var polling: Task<Void, Never>?
    /// 有在等回执的话：还没结果的投送请求（手机发出的，Mac 发给本机或别的 Mac 的），或对 Cue 说了还没交给它的话
    /// （`startSpeechClock` 跟着资料库更新），只给 `pollingCadence` 用。
    var hasOpenDeliveries = false
    /// 正在显示的 Agent 页与会话近况页数（iPad 可能多个窗口）；大于 0 时主动拉，见 `pollingCadence`。
    var piViewers = 0
    /// 有人在看的 Cue 页数（`CueViewing`；各平台、各窗口同一个数）：这台设备开着 Cue 页（`ViewerKeeper.showCue`）、iOS 前台的系统横幅弹不弹；
    /// 手机上大于 0 时按节奏拉（`pollingCadence`）。
    var cueViewers = 0
    #if os(macOS)
    /// 主窗口露在屏上（没缩进程序坞、没被别的窗口整个盖住、App 没隐藏），有没有焦点都算（`ViewerKeeper.follow` 写）。
    var mainWindowExposed = true
    /// 人不在跟前：睡眠、屏幕睡了、锁屏、`SessionPresence.window` 没动键盘鼠标、他去了别的设备（`ViewerKeeper.Away` 有没有，它写）。
    var away = false
    /// 这台 Mac 上的人看得到主窗口：开着的页算在看（会话页、Cue 页的在场、读过与提示都只认它）。
    var seesMainWindow: Bool { mainWindowExposed && !away }
    #endif
    /// 还没返回的那一次立即同步（`syncNow`：启动、回到前台、下拉刷新、"立即同步"按钮）：期间再要立即同步的等它。
    /// 拉取（`CloudSync.syncNow`）只合并还没开拉的那一拉，立即同步要的是"这一次还没返回的"，所以另记。
    var syncing: Task<Void, Never>?
    @ObservationIgnored var syncConnected = false
    var isSyncingNow: Bool { syncing != nil }
    @ObservationIgnored let flights = Flights()
    /// 上次写进共享容器的快照；内容没变就不重写、不刷新小组件。
    @ObservationIgnored var publishedSnapshots: WidgetSnapshots?
    /// 这台设备开着哪一页的唯一写入口；手机拿不到 identifierForVendor 时没有。
    @ObservationIgnored let viewer: ViewerKeeper?
    /// 进入后台前要落盘的界面状态（如编辑中的草稿）。
    @ObservationIgnored var backgroundFlushes: [UUID: @MainActor () async -> Void] = [:]

    /// 系统通知（App 代理持有的那一个，`start()` 前接上）；测试没有，不发真实通知。
    @ObservationIgnored weak var alerts: AlertCenter?

    #if os(iOS)
    @ObservationIgnored let pasteboard: UIPasteboard
    /// 手机实时活动：本地负责开启与身份失效时撤销，远程内容由 Mac 发布。
    /// 隔离实例默认不开，避免遗留活动唤醒测试宿主；验收用 `-CuePadLiveActivity YES`。
    @ObservationIgnored private(set) var cueActivity: CueLiveActivity?
    #endif

    #if os(macOS)
    let agents: AgentIntegrations
    /// 命令行工具 `cuepad` 的安装（链接到 ~/.local/bin）。
    let commandLineTool: CommandLineToolInstaller
    let updates: UpdateService
    /// 主窗口（显隐规则在它身上）；全局快捷键经它。测试没有窗口。
    @ObservationIgnored var windowShell: MainShellWindow?

    @ObservationIgnored let paths: AgentPaths
    @ObservationIgnored let terminal: PiTerminalJumper
    @ObservationIgnored let hooks: AgentHookServer
    @ObservationIgnored let runtimes: [AgentKind: any AgentRuntime]
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored let historyStore: PiHistoryPersistence
    @ObservationIgnored let hotkeyBackend: any HotkeyBackend
    /// 这台 Mac 的稳定标识：Pi 状态记录与投送请求都靠它区分是哪台 Mac。
    @ObservationIgnored let hostID: String
    /// 项目的工作区放在哪（`Workspaces`）：没绑文件夹的项目在这台 Mac 开工时建在这里。
    @ObservationIgnored let workspaces: Workspaces
    @ObservationIgnored let wakeNotifications: NotificationCenter
    @ObservationIgnored let piStateRecorder: PiStateRecorder
    /// 这台 Mac 的在线记录；`start()` 时开始续期，退出时写成离线。
    @ObservationIgnored let presence: MacPresenceKeeper
    /// 这台 Mac 上的 Agent 能不能用（同步表 macAgents）的唯一写入口；`start()` 时开始跟着接入状态与唤醒问，Cue 启用前也经它问。
    @ObservationIgnored let macAgents: MacAgentsRecorder
    /// 这台 Mac 的技能与规则（同步表 agentLibraries）的唯一写入口，整理与改规则也经它。
    @ObservationIgnored let library: AgentLibraryKeeper
    @ObservationIgnored lazy var executor = MacExecutor(
        store: store, pi: pi, runtimes: runtimes, hostID: hostID, workspaces: workspaces, recorder: piStateRecorder, library: library,
        upload: { [weak self] id in await self?.upload(id) },
        fetchFile: { [sync] key in try await sync.fetchFile(key) },
        refreshQuota: { [weak self] in await self?.refreshQuota(.manual) },
        reportIssue: { [weak self] message in self?.reportIssue(.syncUnavailable(message)) })

    @ObservationIgnored lazy var hotkey = GlobalHotkey(
        label: String(localized: "显示或隐藏 CuePad"), key: AppSettings.Key.globalShortcut, defaultAccelerator: "Alt+Space", defaults: settings.defaults,
        backend: hotkeyBackend
    ) { [weak self] in self?.windowShell?.toggleFromHotkey() }
    #endif

    nonisolated enum StartupIssue: Equatable {
        case globalShortcutUnavailable(String)
        /// 分享扩展留下的内容没能入库（保留在共享容器里，下次再试）。
        case captureImportFailed(String)
        /// 跟着库常驻、经同步与别的设备往来的本机功能没能启动或停了：是哪一项写在原因里（各处 `follow(reporting:)`）。
        case syncUnavailable(String)
        case widgetDataUnavailable(String)
        #if os(macOS)
        case piBridgeUnavailable(String)
        /// Pi 历史索引读写 Store 失败；该会话文件不再写回。
        case piHistoryUnavailable(String)
        #endif
    }

    // 资料库是唯一事实源：打不开时不能悄悄换一个空库，也不能带着它往下走——错误交给调用方，启动入口显示失败页
    // （`UnreadableLibraryView`：原因、重试、导出诊断，不给任何写入入口），不终止进程。
    #if os(macOS)
    init(location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, mac: MacDependencies) throws {
        let store = try CueStore(location: location, timing: mac.timing)
        try Self.launch(store, on: mac.hostID, bridge: mac.pi)
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
        piStateRecorder = PiStateRecorder(store: store, hostID: mac.hostID, timing: mac.timing)
        presence = MacPresenceKeeper(store: store, sync: self.sync, host: mac.hostID)
        viewer = ViewerKeeper(store: store, sync: self.sync, device: mac.hostID)
        pi = mac.pi
        pasteboard = mac.pasteboard
        hotkeyBackend = mac.hotkeys
        paths = mac.paths
        terminal = mac.terminal
        hooks = mac.hooks
        runtimes = mac.runtimes(store)
        agents = mac.agents
        macAgents = MacAgentsRecorder(store: store, sync: self.sync, host: mac.hostID, agents: agents)
        // 隔离运行时移走的不进系统废纸篓，放在库里
        let trash = location.touchesRealWorld ? nil : AgentLibraryFiles.trash(into: location.directory.appending(path: "Trash", directoryHint: .isDirectory))
        library = AgentLibraryKeeper(
            store: store, sync: self.sync, host: mac.hostID, files: AgentLibraryFiles(access: agents.integration.fileAccess, trash: trash))
        commandLineTool = mac.commandLineTool
        updates = UpdateService(updater: mac.updater, bridge: mac.pi, runtimes: runtimes)
        historyStore = PiHistoryPersistence(storage: store, host: mac.hostID)
        cue = CueService(
            recorder: piStateRecorder, sync: self.sync, library: location.directory,
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

    /// 这条提示此刻到不到你（`CueStore.reaches`）；读不出就照常提示，宁可多响一次也不悄悄吞掉。
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

    /// 同步从不通变通时立即同步一次（`syncNow`）：断网时没传上去的记录（留在库里待推送）当场传出、在等的回执当场拉回，
    /// 不等发送者的退避；按节奏的拉取也随之重开一个窗口（`pollingCondition`）。
    /// Mac 停下同步等更新时当场查一次更新（`UpdateService.checkInBackground`）。
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
