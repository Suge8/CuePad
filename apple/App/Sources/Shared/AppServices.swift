import Foundation
import Observation
import CueStore
import CueEditor
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
    nonisolated static let bundleID = "com.sugeh.cuepad"
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

    /// 设备本地偏好（主题、快捷键、当前项目）。
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
    }

    /// iCloud 同步；没有时 `syncStatus` 是写明原因的 `.unavailable`。状态、问题与冲突见下，动作见 `AppServices+Sync`。
    @ObservationIgnored let sync: (any SyncControlling)?
    private(set) var syncStatus: SyncStatus
    private(set) var syncIssues: [SyncIssue] = []
    /// 同步在一页页地拉积压（`SyncState.catchingUp`）；界面只经 `isCatchingUp` 读。
    private(set) var syncCatchingUp = false
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
    /// 订阅账号的额度，整个 App 一份（`start()` 开始跟随）。
    let accountQuotas = AccountQuotas()
    /// 待用户处理的正文冲突（同一张卡离线并发编辑产生的副本）。
    private(set) var conflicts: [CardConflict] = []

    /// 小组件、分享扩展打开 App 的链接，界面处理后调用 `consumeDeepLink()`。
    private(set) var pendingDeepLink: DeepLink?

    /// 常驻的跟随者（`follow`），一起取消（`cancelBackgroundWork`）。
    @ObservationIgnored let tasks = Followers()
    /// 有理由等就拉的任务（见 `startPolling`）；iOS 进入后台时取消、回前台再开。
    @ObservationIgnored var polling: Task<Void, Never>?
    /// 有在等回执的话：还没结果的投送请求（手机发出的，Mac 发给本机或别的 Mac 的），或对 Cue 说了还没交给它的话
    /// （`startSpeechClock` 跟着资料库更新），只给 `pollingCadence` 用。
    var hasOpenDeliveries = false
    /// 正在显示的 Agent 页与会话近况页数（iPad 可能多个窗口）；大于 0 时主动拉，见 `pollingCadence`。
    var piViewers = 0
    /// 在前台的 Cue 页数（各平台、各窗口同一个数）：Cue 的通知按它算你在不在看（Mac 见 `Workspace.presentation`，iOS 前台的系统横幅）；
    /// 手机上大于 0 时按节奏拉（`pollingCadence`）。
    var cueViewers = 0
    /// 还没返回的那一次立即同步（`syncNow`：启动、回到前台、下拉刷新、"立即同步"按钮）：期间再要立即同步的等它，不另拉一遍。
    var syncing: Task<Void, Never>?
    /// 立即同步还没返回：按钮的忙碌与禁用读 `canSyncNow`，"本机是不是最新"读 `isCatchingUp`。
    var isSyncingNow: Bool { syncing != nil }
    /// 上次写进共享容器的快照；内容没变就不重写、不刷新小组件。
    @ObservationIgnored var publishedSnapshots: WidgetSnapshots?
    /// 进入后台前要落盘的界面状态（如编辑中的草稿）；见 `prepareForBackground()`。
    @ObservationIgnored var backgroundFlushes: [UUID: @MainActor () async -> Void] = [:]

    #if os(iOS)
    @ObservationIgnored let pasteboard: UIPasteboard
    #endif

    #if os(macOS)
    /// 接入各个 Agent（技能，Pi 另有扩展）的检测、安装与卸载。
    let agents: AgentIntegrations
    /// 命令行工具 `cuepad` 的安装（链接到 ~/.local/bin）。
    let commandLineTool: CommandLineToolInstaller
    /// 自动更新（Sparkle）。
    let updates: UpdateService
    /// 主窗口（显隐规则在它身上）；全局快捷键经它。测试没有窗口。
    @ObservationIgnored var windowShell: MainShellWindow?
    /// 系统通知（App 代理持有的那一个，`start()` 前接上）；测试没有，不发真实通知。
    @ObservationIgnored weak var alerts: AlertCenter?

    @ObservationIgnored let paths: AgentPaths
    @ObservationIgnored let terminal: PiTerminalJumper
    @ObservationIgnored let hooks: AgentHookServer
    @ObservationIgnored let runtimes: [AgentKind: any AgentRuntime]
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored let historyStore: PiHistoryPersistence
    @ObservationIgnored let hotkeyBackend: any HotkeyBackend
    /// 这台 Mac 的稳定标识：Pi 状态记录与投送请求都靠它区分是哪台 Mac。
    @ObservationIgnored let hostID: String
    @ObservationIgnored let wakeNotifications: NotificationCenter
    @ObservationIgnored let piStateRecorder: PiStateRecorder
    /// 这台 Mac 的在线记录；`start()` 时开始续期，退出时写成离线。
    @ObservationIgnored let presence: MacPresenceKeeper
    /// 这台 Mac 上的 Agent 能不能用（同步表 macAgents）的唯一写入口；`start()` 时开始跟着接入状态与唤醒问，Cue 启用前也经它问。
    @ObservationIgnored let macAgents: MacAgentsRecorder
    /// 执行发给这台 Mac 的投送请求（手机发来的与本机界面写的）；`start()` 时启动。
    @ObservationIgnored lazy var executor = MacExecutor(
        store: store, pi: pi, runtimes: runtimes, hostID: hostID, recorder: piStateRecorder,
        upload: { [weak self] id in await self?.upload(id) },
        refreshQuota: { [weak self] in try await self?.refreshQuotaForRequest() },
        reportIssue: { [weak self] message in self?.reportIssue(.syncUnavailable(message)) })

    /// "显示或隐藏 CuePad"的全局快捷键。
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
        /// 小组件与分享扩展用的快照写不出来。
        case widgetDataUnavailable(String)
        #if os(macOS)
        case piBridgeUnavailable(String)
        /// Pi 历史索引读写 Store 失败；该会话文件不再写回。
        case piHistoryUnavailable(String)
        #endif
    }

    /// 撤回一句说出去的话（排队的话、重发或移除没能送达的话）：发给会话的，还没被 Mac 领取的才撤得回，没能送达的直接删；
    /// 对 Cue 说的，还没交给它的才撤得回。撤了立即把删除传上去，免得 Mac 先拉到它；撤不回时抛出原因。
    func withdraw(_ said: Said) async throws {
        switch said {
        case .request(let request) where request.status == .known(.failed):
            try await store.deleteDelivery(request.id)
        case .request(let request):
            guard try await store.withdrawDelivery(request.id) else { throw SendError.alreadyHanded }
        case .cue(let message, _):
            guard try await store.withdrawCueMessage(message.id) else { throw SendError.alreadyHeard }
        }
        Task { await upload(said.id, deleted: true) }
    }

    /// 把还没被 Mac 领取的"等它做完再说"改成"马上说"，立即上传；已领取的改不了，抛出原因。
    func promote(_ request: DeliveryRequest) async throws {
        guard try await store.promoteDelivery(request.id) else { throw SendError.alreadyHanded }
        Task { await upload(request.id) }
    }

    /// 发往别的设备的请求写出后立即上传（不等它完成），见 `upload`。
    func uploaded(_ request: DeliveryRequest) -> DeliveryRequest {
        Task { await upload(request.id) }
        return request
    }

    /// 改 Cue 的设置（同步的 `CueProfile`）：两端的写入口——名字、停用、Agent、模型与思考强度；启用另走 `enableCue`（要按那台 Mac 判断）。
    /// 写库后马上传这一条，别的设备马上看到；Cue 住的那台 Mac 的管理器读到就按新设置值班。
    func updateCue(_ edit: @escaping @Sendable (inout CueProfile) -> Void) async throws {
        try await store.updateCueProfile(edit)
        await sync?.upload(CueProfile.recordID)
    }

    /// 让 Cue 住在 `host` 那台 Mac 并启用（规则 `CueStore.enableCue`）：两端同一个入口。是这台 Mac 时先重新探测一次本机的 Agent
    /// （刚启动还没探测完也不会按旧的或空的判断）；别的 Mac 按它同步来的那条。写完马上传。
    func enableCue(on host: String) async throws {
        #if os(macOS)
        if host == hostID { try await macAgents.record() }
        #endif
        try await store.enableCue(on: host)
        await sync?.upload(CueProfile.recordID)
    }

    /// 停用 Cue（住在哪台留着）。
    func disableCue() async throws {
        try await updateCue { $0.enabledAt = nil }
    }

    /// 马上传这一条（`SyncControlling.upload`）：手机写出投送请求、Mac 写回结果、Mac 写出带通知标志的会话状态后都调用。没有同步时什么也不做。
    func upload(_ record: UUID, deleted: Bool = false) async {
        await sync?.upload(record, deleted: deleted)
    }

    /// 回答会话正在等的弹窗：写一条作答请求给会话所在的 Mac（与发送同一条投送通道，Mac 上也走它，由执行器交给扩展）。
    /// 问题不能从这里作答（没有标识或种类不认识）时抛 `SendError.unanswerable`。
    func answer(_ value: PiAnswerValue, to session: PiSessionState) async throws -> DeliveryRequest {
        guard let question = session.question, question.isAnswerable, let promptID = question.promptID else {
            throw SendError.unanswerable
        }
        return uploaded(try await store.requestAnswer(
            PiAnswer(promptID: promptID, value: value), to: session.target,
            on: session.hostID))
    }

    /// 换会话的模型或思考强度：写一条配置请求给会话所在的 Mac（与发送、作答同一条投送通道，Mac 上也走它），写出后立即上传。
    /// 当前值与可选项读会话状态的 `model`、`thinking`、`models`；结果用 `CueStore.outcome(of:)` 等。
    func configure(_ config: PiConfig, for session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestConfig(
            config, to: session.target, on: session.hostID))
    }

    /// 结束会话：请会话所在的 Mac 让它的 Pi 进程正常退出（与发送、作答同一条投送通道，Mac 上也走它），写出后立即上传。
    /// 会话记录与对话都留着，之后再给它发消息会在后台恢复；已经结束的会话也算成功。结果用 `CueStore.outcome(of:)` 等。
    func end(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestEnd(
            of: session.target, on: session.hostID))
    }

    /// 停止这一轮：请会话所在的 Mac 中止它正在跑的回合（相当于在 Pi 里按 Esc；与发送、作答同一条投送通道，Mac 上也走它），写出后立即上传。
    /// 会话随后回到等你下一句（状态记录里是"完成"，被中止）；只停指挥官自己这一轮，子代理照常跑；已经结束或空闲的会话也算成功。
    /// 结果用 `CueStore.outcome(of:)` 等；界面只在会话 `state.isTurnRunning` 时给入口（等子代理时指挥官没有在跑的一轮）。
    func stop(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestStop(
            of: session.target, on: session.hostID))
    }

    /// 请指定的 Mac 在后台开一个 Pi 新会话：与发送同一条投送通道（Mac 本机也走它），写出后立即上传。
    /// `title` 是给人看的目标名（会话名或项目名）。新会话用 `PiLaunch` 的 `token` 认领：等同步记录上出现同一个
    /// `launchToken` 的会话。
    /// `card`：从这条灵感或任务开的（开好后它关联到新会话，见 `CueStore.claimLaunchedCards`）。
    func launch(_ launch: PiLaunch, title: String, on host: String, card: UUID? = nil) async throws -> DeliveryRequest {
        uploaded(try await store.requestLaunch(launch, title: title, on: host, card: card))
    }

    /// 请 `host` 那台 Mac 给项目绑定文件夹（`PiBind.folder` 为 nil 是解除；手机没有完整路径，由那台 Mac 解析并写本机的目录绑定），
    /// 与发送同一条投送通道，写出后立即上传。结果用 `CueStore.outcome(of:)`；绑好后目录绑定记录随同步回来。
    func requestBind(_ bind: PiBind, title: String, on host: String) async throws -> DeliveryRequest {
        uploaded(try await store.requestBind(bind, title: title, on: host))
    }

    /// 请会话所在的 Mac 把这个会话的对话补写进来（7 天前活跃过、还没有对话的会话打开时调用），写出后立即上传。
    func requestTranscript(of session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestTranscript(of: session))
    }

    /// 连接测试一次往返的分段。`upload`（写库完成 → 上传完成）与 `total`（开始写库 → 看到结果）用本机时钟；`toMac`（上传完成 → Mac 执行完）与 `back`（Mac 执行完 → 本机看到）
    /// 用 Mac 写回的完成时间，跨设备时钟，有误差（两台设备的时钟一般相差零点几秒，偶尔为负）。
    struct PingTiming: Sendable {
        var upload: Duration
        var toMac: Duration
        var back: Duration
        var total: Duration
    }

    /// 连接测试：给 `host` 那台 Mac 发一条 ping（与发送同一套投送请求），立即上传，等它写回结果，返回分段的往返时间。
    /// 超过 `timeout` 没有结果、或结果是失败时抛 `SendError.notDelivered`。
    /// 用过的请求删掉。
    func ping(_ host: String, timeout: Duration = .seconds(60)) async throws -> PingTiming {
        let started = ContinuousClock.now
        let request = try await store.requestPing(on: host)
        let written = ContinuousClock.now
        defer {
            Task { [store] in
                do {
                    try await store.deleteDelivery(request.id)
                } catch {
                    Self.log.error("连接测试的请求没能删掉：\(error.localizedDescription)")
                }
            }
        }
        async let seen = result(of: request.id, within: timeout)
        await upload(request.id)
        let uploaded = (instant: ContinuousClock.now, date: Date())
        guard let (result, seenAt) = try await seen else {
            throw SendError.notDelivered("\(timeout.components.seconds) 秒内 Mac 没有回应")
        }
        if let reason = result.failure { throw SendError.notDelivered(reason) }
        let completed = result.completedAt ?? seenAt.date
        return PingTiming(
            upload: uploaded.instant - written, toMac: .seconds(completed.timeIntervalSince(uploaded.date)),
            back: .seconds(seenAt.date.timeIntervalSince(completed)), total: seenAt.instant - started)
    }

    /// 等请求有结果，最多 `timeout`；超时返回 nil。同时记下本机看到结果的时刻。
    func result(
        of request: DeliveryRequest.ID, within timeout: Duration
    ) async throws -> (DeliveryRequest, seenAt: (instant: ContinuousClock.Instant, date: Date))? {
        try await withThrowingTaskGroup(of: (DeliveryRequest, seenAt: (instant: ContinuousClock.Instant, date: Date))?.self) { group in
            group.addTask {
                let done = try await self.store.outcome(of: request)
                return (done, (ContinuousClock.now, Date()))
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    #if os(macOS)
    init(location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, mac: MacDependencies) throws {
        let store = try Self.openLibrary(at: location, timing: mac.timing)
        self.store = store
        settings = AppSettings(defaults: defaults)
        self.location = location
        diagnostics = Diagnostics(directory: location.directory.appending(path: "Diagnostics", directoryHint: .isDirectory))
        let (engine, status) = Self.makeSync(sync, store: store, location: location)
        (self.sync, syncStatus) = (engine, status)
        speechClock = SpeechClock(localHost: mac.hostID, reachable: status.reachesMac, alwaysReachable: DebugHooks.preset.alwaysReachable, timing: mac.timing)
        liveSessions = try LiveSessions(store: store, endedOn: mac.hostID, at: speechClock.moment)
        timing = mac.timing
        hostID = mac.hostID
        wakeNotifications = mac.wakeNotifications
        piStateRecorder = PiStateRecorder(store: store, hostID: mac.hostID)
        presence = MacPresenceKeeper(store: store, sync: self.sync, host: mac.hostID)
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
            store: store, sync: self.sync, hostID: mac.hostID, library: location.directory,
            piAgentDirectory: mac.paths.pi.agentDirectory, dependencies: mac.cue)
    }
    #else
    init(
        location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, pasteboard: UIPasteboard = .general, timing: Timing = .system
    ) throws {
        let store = try Self.openLibrary(at: location, timing: timing)
        self.store = store
        settings = AppSettings(defaults: defaults)
        self.location = location
        diagnostics = Diagnostics(directory: location.directory.appending(path: "Diagnostics", directoryHint: .isDirectory))
        let (engine, status) = Self.makeSync(sync, store: store, location: location)
        (self.sync, syncStatus) = (engine, status)
        speechClock = SpeechClock(localHost: nil, reachable: status.reachesMac, alwaysReachable: DebugHooks.preset.alwaysReachable, timing: timing)
        liveSessions = try LiveSessions(store: store, endedOn: nil, at: speechClock.moment)
        self.timing = timing
        self.pasteboard = pasteboard
    }
    #endif

    /// 资料库是唯一事实源：打不开时不能悄悄换一个空库，也不能带着它往下走——错误交给调用方，启动入口显示失败页
    /// （`UnreadableLibraryView`：原因、重试、导出诊断，不给任何写入入口），不终止进程。
    static func openLibrary(at location: LibraryLocation, timing: Timing = .system) throws -> CueStore {
        try CueStore(url: location.databaseURL, timing: timing)
    }

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

    /// 同步从不通变通时立即同步一次（`syncNow`）：断网时没传上去的记录（留在库里待推送）当场传出、在等的回执当场拉回，
    /// 不等发送者的退避；按节奏的拉取也随之重开一个窗口（`pollingCondition`）。
    func setSyncState(_ state: SyncState) {
        let recovered = state.status.reachesMac && speech.reachableSince == nil
        syncStatus = state.status
        speechClock.setReachable(state.status.reachesMac)
        if recovered { Task { await syncNow() } }
        syncIssues = state.issues
        syncCatchingUp = state.catchingUp
        alertSubscription = state.alerts
    }

    func setConflicts(_ conflicts: [CardConflict]) {
        self.conflicts = conflicts
    }

    func setDeepLink(_ link: DeepLink?) {
        pendingDeepLink = link
    }

    func reportIssue(_ issue: StartupIssue) {
        Self.log.error("\(String(describing: issue))")
        startupIssues.append(issue)
    }
}

nonisolated extension PiSessionState {
    /// 投送请求里指这个会话的目标（`ref` 是 Pi 自己的会话 id）。
    var target: SendTarget { SendTarget(kind: .piSession, name: title, ref: sessionID) }
}
