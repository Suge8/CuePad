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
    nonisolated static let bundleID = AppIdentity.id
    /// 给人看的版本："0.1.0（1）"。
    static let version: String = {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?")（\(info?["CFBundleVersion"] as? String ?? "?")）"
    }()
    static let log = Logger(subsystem: bundleID, category: "services")

    let store: CueStore
    #if os(macOS)
    let pi: PiBridge
    /// 总控 Agent Cue（只在 Mac 上值班）。
    let cue: CueService
    #endif

    let settings: AppSettings
    /// 启动期间没能完成的事；界面据此提示，不静默。
    private(set) var startupIssues: [StartupIssue] = []

    @ObservationIgnored let location: LibraryLocation
    /// 崩溃诊断（MetricKit）：设置页的"上次崩溃"。
    let diagnostics: Diagnostics

    /// iCloud 同步从哪来：正式启动按位置与本构建的 iCloud 权限决定（`makeSync`），测试注入替身。
    /// 没有默认值：入口必须写明，不能悄悄没有同步。
    enum SyncSource {
        case iCloud
        case custom(any SyncControlling)
        /// 用本机的库建的同步：真实的同步代码连替身 iCloud（`CloudSync` 的替身连接），给测试与调试画面。
        case built((CueStore) -> any SyncControlling)
    }

    /// iCloud 同步；没有时 `syncStatus` 是写明原因的 `.unavailable`。状态、问题与冲突见下，动作见 `AppServices+Sync`。
    @ObservationIgnored let sync: (any SyncControlling)?
    private(set) var syncStatus: SyncStatus
    private(set) var syncIssues: [SyncIssue] = []
    /// 同步在一页页地拉积压（`SyncState.catchingUp`）；界面只经 `isCatchingUp` 读。
    private(set) var syncCatchingUp = false
    /// 这台的库和 iCloud 对过至少一遍（`SyncState.reconciled`）；界面只经 `knowsSyncedFacts` 读。
    private(set) var syncReconciled = false
    /// Pi 锁屏通知的服务端订阅（只有 iOS 建立）；设置页与权限、注册状态一起显示。
    private(set) var alertSubscription: PiAlertSubscriptionStatus = .off
    #if os(iOS)
    /// 最近一次要在前台提示的会话转换（见 `startSessionAlerts`）；每个窗口自己决定弹不弹。
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
    /// 订阅账号的额度，整个 App 一份（`start()` 开始跟随）。
    let accountQuotas = AccountQuotas()
    /// 待用户处理的正文冲突（同一张卡离线并发编辑产生的副本）。
    private(set) var conflicts: [CardConflict] = []

    /// 小组件、分享扩展、实时活动的链接与点开的通知要打开的页（`handle(url:)`、`AlertCenter.receive`），工作区取走（`Workspace.openLinks`）。
    var pendingDeepLink: DeepLink?

    /// 常驻的跟随者（`follow`），一起取消（`cancelBackgroundWork`）。
    @ObservationIgnored let tasks = Followers()
    /// 有理由等就拉的任务（见 `startPolling`）；iOS 进入后台时取消、回前台再开。
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
    /// 人不在跟前：睡眠、屏幕睡了、锁屏、`SessionPresence.window` 没动键盘鼠标（`ViewerKeeper.Away` 有没有，它写）。
    var away = false
    /// 这台 Mac 上的人看得到主窗口：开着的页算在看（会话页、Cue 页的在场、读过与提示都只认它）。
    var seesMainWindow: Bool { mainWindowExposed && !away }
    #endif
    /// 最近一拉（`pull`）：开拉的时刻与它的任务，拉完也留着（等它立即返回）。同步启动时先是那次启动（不是一拉，没有开拉时刻）。
    @ObservationIgnored var latestPull: (began: ContinuousClock.Instant?, task: Task<Void, Never>)?
    /// 还没返回的那一次立即同步（`syncNow`：启动、回到前台、下拉刷新、"立即同步"按钮）：期间再要立即同步的等它。
    /// 拉取入口（`pull`）只合并开拉不早于要的那一刻的一拉，立即同步要的是"这一次还没返回的"，所以另记。
    var syncing: Task<Void, Never>?
    /// 立即同步还没返回：按钮的忙碌与禁用读 `canSyncNow`，"本机是不是最新"读 `isCatchingUp`。
    var isSyncingNow: Bool { syncing != nil }
    /// 上次写进共享容器的快照；内容没变就不重写、不刷新小组件。
    @ObservationIgnored var publishedSnapshots: WidgetSnapshots?
    /// 这台设备开着哪一页的唯一写入口；手机拿不到 identifierForVendor 时没有。
    @ObservationIgnored let viewer: ViewerKeeper?
    /// 进入后台前要落盘的界面状态（如编辑中的草稿）；见 `prepareForBackground()`。
    @ObservationIgnored var backgroundFlushes: [UUID: @MainActor () async -> Void] = [:]

    /// 系统通知（App 代理持有的那一个，`start()` 前接上）；测试没有，不发真实通知。
    @ObservationIgnored weak var alerts: AlertCenter?

    #if os(iOS)
    @ObservationIgnored let pasteboard: UIPasteboard
    /// 锁屏与灵动岛上的那一个实时活动（`startSnapshots` 跟着库开、改、结束它）。不碰真实世界时（`LibraryLocation.touchesRealWorld`：测试、脚本起的调试实例）没有：
    /// 实例被结束时开着的活动留在系统里，下次装 App 时系统为它把 App 叫到后台，正好撞上测试宿主的启动（测试进程连不上）；
    /// 验收实时活动时用 `-CuePadLiveActivity YES` 打开（`DebugHooks.opensLiveActivity`）。
    @ObservationIgnored let cueActivity: CueLiveActivity?
    #endif

    #if os(macOS)
    /// 接入各个 Agent（技能，Pi 另有扩展）的检测、安装与卸载。
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
    /// 执行发给这台 Mac 的投送请求（手机发来的与本机界面写的）；`start()` 时启动。
    @ObservationIgnored lazy var executor = MacExecutor(
        store: store, pi: pi, runtimes: runtimes, hostID: hostID, workspaces: workspaces, recorder: piStateRecorder,
        upload: { [weak self] id in await self?.upload(id) },
        refreshQuota: { [weak self] in try await self?.refreshQuotaForRequest() },
        reportIssue: { [weak self] message in self?.reportIssue(.syncUnavailable(message)) })

    @ObservationIgnored lazy var hotkey = GlobalHotkey(
        label: "显示或隐藏 CuePad", key: AppSettings.Key.globalShortcut, defaultAccelerator: "Alt+Space", defaults: settings.defaults,
        backend: hotkeyBackend
    ) { [weak self] in self?.windowShell?.toggleFromHotkey() }
    #endif

    nonisolated enum StartupIssue: Equatable {
        case globalShortcutUnavailable(String)
        /// 分享扩展留下的内容没能入库（保留在共享容器里，下次再试）。
        case captureImportFailed(String)
        /// iCloud 同步（或依赖它的 Mac 端远程功能）没能启动。
        case syncUnavailable(String)
        case widgetDataUnavailable(String)
        #if os(macOS)
        case piBridgeUnavailable(String)
        /// Pi 历史索引读写 Store 失败；该会话文件不再写回。
        case piHistoryUnavailable(String)
        #endif
    }

    /// 改 Cue 的设置（同步的 `CueProfile`）：两端的写入口——名字、停用、Agent、模型与思考强度；启用另走 `enableCue`（要按那台 Mac 判断）。
    /// 写库后马上传这一条，别的设备马上看到；Cue 运行的那台 Mac 的管理器读到就按新设置值班。
    func updateCue(_ edit: @escaping @Sendable (inout CueProfile) -> Void) async throws {
        try await store.updateCueProfile(edit)
        await upload(CueProfile.recordID)
    }

    /// 让 Cue 运行在 `host` 那台 Mac 并启用（规则 `CueStore.enableCue`）：两端所有入口都经这里，界面读的是同一处判断（`CueGate`）。
    /// 这台的库还没和 iCloud 对过一遍时拒绝（`CueEnableError.unsynced`）：库里没有 Cue 不等于哪台都没设过，启用了会把它从原来那台抢过来；
    /// 它正在别的 Mac 上运行时，只有 `moving`（你确认了改在这台运行）才改。是这台 Mac 时先重新探测一次本机的 Agent
    /// （刚启动还没探测完也不会按旧的或空的判断）；别的 Mac 按它同步来的那条。写完马上传。
    func enableCue(on host: String, moving: Bool) async throws {
        guard knowsSyncedFacts else { throw CueEnableError.unsynced }
        #if os(macOS)
        if host == hostID { try await macAgents.record() }
        #endif
        try await store.enableCue(on: host, moving: moving)
        await upload(CueProfile.recordID)
    }

    // 资料库是唯一事实源：打不开时不能悄悄换一个空库，也不能带着它往下走——错误交给调用方，启动入口显示失败页
    // （`UnreadableLibraryView`：原因、重试、导出诊断，不给任何写入入口），不终止进程。
    #if os(macOS)
    init(location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, mac: MacDependencies) throws {
        let store = try CueStore(location: location, timing: mac.timing)
        self.store = store
        settings = AppSettings(defaults: defaults)
        self.location = location
        diagnostics = Diagnostics(directory: location.directory.appending(path: "Diagnostics", directoryHint: .isDirectory))
        let (engine, status) = Self.makeSync(sync, store: store, location: location)
        (self.sync, syncStatus) = (engine, status)
        speechClock = SpeechClock(localHost: mac.hostID, reachable: status.reachesMac, alwaysReachable: DebugHooks.preset.alwaysReachable, timing: mac.timing)
        liveSessions = try LiveSessions(store: store, endedOn: mac.hostID, at: speechClock.moment)
        cueFeed = CueFeed(store: store, widget: false)
        timing = mac.timing
        hostID = mac.hostID
        workspaces = mac.workspaces
        wakeNotifications = mac.wakeNotifications
        piStateRecorder = PiStateRecorder(store: store, hostID: mac.hostID)
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
        commandLineTool = mac.commandLineTool
        updates = UpdateService(updater: mac.updater, bridge: mac.pi)
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
        (self.sync, syncStatus) = (engine, status)
        speechClock = SpeechClock(localHost: nil, reachable: status.reachesMac, alwaysReachable: DebugHooks.preset.alwaysReachable, timing: timing)
        liveSessions = try LiveSessions(store: store, endedOn: nil, at: speechClock.moment)
        cueFeed = CueFeed(store: store, widget: true)
        self.timing = timing
        self.pasteboard = pasteboard
        cueActivity = location.touchesRealWorld || DebugHooks.opensLiveActivity ? CueLiveActivity() : nil
        viewer = UIDevice.current.identifierForVendor.map { [sync = self.sync] in
            ViewerKeeper(store: store, sync: sync, device: $0.uuidString)
        }
    }
    #endif

    /// 同步没能启动：状态写明原因（与启动问题一起），不停在"正在连接"。
    func syncFailedToStart(_ error: any Error) {
        let reason = "同步没能启动：\(error.localizedDescription)"
        syncStatus = .unavailable(reason)
        speechClock.setReachable(false)
        reportIssue(.syncUnavailable(reason))
    }

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

    /// 同步从不通变通时立即同步一次（`syncNow`）：断网时没传上去的记录（留在库里待推送）当场传出、在等的回执当场拉回，
    /// 不等发送者的退避；按节奏的拉取也随之重开一个窗口（`pollingCondition`）。
    func setSyncState(_ state: SyncState) {
        let recovered = state.status.reachesMac && speech.reachableSince == nil
        syncStatus = state.status
        speechClock.setReachable(state.status.reachesMac)
        if recovered { Task { await syncNow() } }
        syncIssues = state.issues
        syncCatchingUp = state.catchingUp
        syncReconciled = state.reconciled
        alertSubscription = state.alerts
    }

    func setConflicts(_ conflicts: [CardConflict]) {
        self.conflicts = conflicts
    }

    func reportIssue(_ issue: StartupIssue) {
        Self.log.error("\(String(describing: issue))")
        startupIssues.append(issue)
    }
}
