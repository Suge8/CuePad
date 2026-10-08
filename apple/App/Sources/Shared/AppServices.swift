import Foundation
import Observation
import CueStore
import CueEditor
import CueSync
import os
#if os(macOS)
import CueDispatch
import CuePi
#else
import UIKit
#endif

/// 组合根与界面动作的唯一入口：持有各模块的唯一实例。
/// 界面读数据直接 `store.observe(...)`；一切副作用（投送、复制、Pi 命令、终端跳转、导入、扩展安装）只经这里，
/// 发送记录也只在这里写。
@MainActor @Observable
final class AppServices {
    static let bundleID = "com.sugeh.cuepad"
    static let log = Logger(subsystem: bundleID, category: "services")

    let store: CueStore
    let images: any CueImageStore
    #if os(macOS)
    let pi: PiBridge
    /// 按 bundle ID 解析出的应用名（运行期间不变）：发送按钮每次绘制都要用，逐次解析要问 LaunchServices 并读应用的 Info.plist。
    @ObservationIgnored var appNames: [String: String] = [:]
    #endif

    /// 设备本地偏好（主题、快捷键、自动发送、当前项目）。
    let settings: AppSettings
    /// 启动期间没能完成的事；界面据此提示，不静默。
    private(set) var startupIssues: [StartupIssue] = []

    @ObservationIgnored let location: LibraryLocation

    /// iCloud 同步引擎从哪来：正式启动按位置与本构建的 iCloud 权限决定（`makeSync`），测试注入替身。
    /// 没有默认值：入口必须写明，不能悄悄没有引擎。
    enum SyncSource {
        case iCloud
        case custom(any SyncControlling)
    }

    /// iCloud 同步引擎；没有时 `syncStatus` 是写明原因的 `.unavailable`。状态、问题与冲突见下，动作见 `AppServices+Sync`。
    @ObservationIgnored let sync: (any SyncControlling)?
    private(set) var syncStatus: SyncStatus
    private(set) var syncIssues: [SyncIssue] = []
    /// Pi 锁屏通知的服务端订阅（只有 iOS 建立）；设置页与权限、注册状态一起显示。
    private(set) var alertSubscription: PiAlertSubscriptionStatus = .off
    #if os(iOS)
    /// 最近一次要在前台提示的会话转换（见 `startSessionAlerts`）；每个窗口自己决定弹不弹。
    private(set) var sessionAlert: SessionAlert?
    #endif
    /// 待用户处理的正文冲突（同一张卡离线并发编辑产生的副本）。
    private(set) var conflicts: [CardConflict] = []

    /// 小组件、分享扩展打开 App 的链接，界面处理后调用 `consumeDeepLink()`。
    private(set) var pendingDeepLink: DeepLink?

    @ObservationIgnored var tasks: [Task<Void, Never>] = []
    /// 有理由等就拉的任务（见 `startPolling`）；iOS 进入后台时取消、回前台再开。
    @ObservationIgnored var polling: Task<Void, Never>?
    /// 有还没结果的投送请求（Mac：发给本机的）。只在主动拉取开着时跟着资料库更新，只给 `pollingCadence` 用。
    var hasOpenDeliveries = false
    /// 正在显示的 Agent 页与会话近况页数（iPad 可能多个窗口）；大于 0 时主动拉，见 `pollingCadence`。
    var piViewers = 0
    /// 上次写进共享容器的快照；内容没变就不重写、不刷新小组件。
    @ObservationIgnored var publishedSnapshots: WidgetSnapshots?
    /// 进入后台前要落盘的界面状态（如编辑中的草稿）；见 `prepareForBackground()`。
    @ObservationIgnored var backgroundFlushes: [UUID: @MainActor () async -> Void] = [:]

    #if os(iOS)
    @ObservationIgnored let pasteboard: UIPasteboard
    #endif

    #if os(macOS)
    /// Pi 扩展的检测与安装（写入前需征得同意）。
    let piExtension: PiExtensionManager
    /// 辅助功能授权（通用投送的前提）。
    let accessibility: AccessibilityAccess
    /// 命令行工具 `cuepad` 的安装（链接到 ~/.local/bin）。
    let commandLineTool: CommandLineToolInstaller
    /// 自动更新（Sparkle）。
    let updates: UpdateService
    /// 主窗口显隐；通用投送前后与全局快捷键都经它。
    @ObservationIgnored var windowShell: WindowShell?

    @ObservationIgnored let channels: any SendChannels
    @ObservationIgnored let paths: PiPaths
    @ObservationIgnored let terminal: PiTerminalJumper
    @ObservationIgnored let locatePi: @Sendable () async -> URL?
    @ObservationIgnored let host: any PiHosting
    @ObservationIgnored let historyStore: PiHistoryPersistence
    @ObservationIgnored let hotkeyBackend: any HotkeyBackend
    /// 这台 Mac 的稳定标识：Pi 状态记录与投送请求都靠它区分是哪台 Mac。
    @ObservationIgnored let hostID: String
    @ObservationIgnored let wakeNotifications: NotificationCenter
    @ObservationIgnored let piStateRecorder: PiStateRecorder
    @ObservationIgnored var deliveryExecutor: DeliveryExecutor?

    @ObservationIgnored lazy var hotkey = GlobalHotkey(backend: hotkeyBackend) { [weak self] in
        self?.windowShell?.toggleFromHotkey()
    }
    #endif

    nonisolated enum StartupIssue: Equatable {
        case legacyImportFailed(String)
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

    /// 发往哪里。正文一律是存储格式（变量已填），图片引用由这里解析成真实图片。
    enum Destination: Equatable {
        #if os(macOS)
        /// 发进 Pi 会话：`send` 在会话忙时报 `SendError.piSessionBusy`，`steer`/`followUp` 忙时马上说或等它做完再说，
        /// `paste` 只把文字放进输入框（含图片时报错）。
        case pi(CuePi.PiSession.ID, DeliveryMode)
        /// 通用投送：剪贴板 + 激活目标 + 定向粘贴；是否回车跟随设置。
        case app(TargetSelector)
        #endif
        /// 只复制到剪贴板。
        case clipboard
    }

    /// 发到 Mac：写一条投送请求，交给运行该 Pi 会话的那台 Mac（取自会话的 `hostID`）执行；
    /// 那台 Mac 执行后写回结果并记发送记录，这里不记。
    @discardableResult
    func requestMacDelivery(
        _ storedText: String, to session: PiSessionState, mode: DeliveryMode, card: UUID? = nil, parts: [UUID] = []
    ) async throws -> DeliveryRequest {
        uploaded(try await store.requestDelivery(
            storedText, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID,
            mode: mode, card: card, parts: parts))
    }

    /// 发往别的设备的请求写出后立即上传（不等它完成），见 `upload`。
    private func uploaded(_ request: DeliveryRequest) -> DeliveryRequest {
        Task { await upload(request.id) }
        return request
    }

    /// 立即只上传这一条记录，不等引擎的自动调度（几秒到几十秒）：手机写出投送请求、Mac 写回结果、Mac 写出带通知标志的
    /// 会话状态后都调用。失败只记日志，引擎会照常重试。返回时这一条已经传完（或失败）。
    func upload(_ record: UUID) async {
        guard let sync else { return }
        do {
            try await sync.sendNow(recordName: record.uuidString.lowercased())
        } catch {
            Self.log.notice("立即上传记录失败，等引擎自动上传：\(String(describing: error), privacy: .public)")
        }
    }

    /// 回答会话正在等的弹窗：写一条作答请求给会话所在的 Mac（与发送同一条投送通道，Mac 上也走它，由执行器交给扩展）。
    /// 问题不能从这里作答（没有标识或种类不认识）时抛 `SendError.unanswerable`。
    func answer(_ value: PiAnswerValue, to session: PiSessionState) async throws -> DeliveryRequest {
        guard let question = session.question, question.isAnswerable, let promptID = question.promptID else {
            throw SendError.unanswerable
        }
        return uploaded(try await store.requestAnswer(
            PiAnswer(promptID: promptID, value: value), to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID),
            on: session.hostID))
    }

    /// 换会话的模型或思考强度：写一条配置请求给会话所在的 Mac（与发送、作答同一条投送通道，Mac 上也走它），写出后立即上传。
    /// 当前值与可选项读会话状态的 `model`、`thinking`、`models`；结果用 `outcome(of:)` 等。
    func configure(_ config: PiConfig, for session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestConfig(
            config, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID))
    }

    /// 结束会话：请会话所在的 Mac 让它的 Pi 进程正常退出（与发送、作答同一条投送通道，Mac 上也走它），写出后立即上传。
    /// 会话记录与对话都留着，之后再给它发消息会在后台恢复；已经结束的会话也算成功。结果用 `outcome(of:)` 等。
    func end(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestEnd(
            of: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID))
    }

    /// 停止这一轮：请会话所在的 Mac 中止它正在跑的回合（相当于在 Pi 里按 Esc；与发送、作答同一条投送通道，Mac 上也走它），写出后立即上传。
    /// 会话随后回到等你下一句（状态记录里是"完成"，被中止）；只停指挥官自己这一轮，子代理照常跑；已经结束或空闲的会话也算成功。
    /// 结果用 `outcome(of:)` 等；界面只在会话 `state.isTurnRunning` 时给入口（等子代理时指挥官没有在跑的一轮）。
    func stop(_ session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestStop(
            of: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID))
    }

    /// 请指定的 Mac 在后台开一个 Pi 新会话：与发送同一条投送通道（Mac 本机也走它），写出后立即上传。
    /// `title` 是给人看的目标名（会话名或项目名）。新会话用 `PiLaunch` 的 `token` 认领：等同步记录上出现同一个
    /// `launchToken` 的会话。
    /// `card`：从这条灵感或任务开的（开好后它关联到新会话，见 `CueStore.claimLaunchedCards`）。
    func launch(_ launch: PiLaunch, title: String, on host: String, card: UUID? = nil) async throws -> DeliveryRequest {
        uploaded(try await store.requestLaunch(launch, title: title, on: host, card: card))
    }

    /// 请会话所在的 Mac 把这个会话的对话补写进来（7 天前活跃过、还没有对话的会话打开时调用），写出后立即上传。
    func requestTranscript(of session: PiSessionState) async throws -> DeliveryRequest {
        uploaded(try await store.requestTranscript(of: session))
    }

    /// 等到投送请求有结果（已送达或没能送达）。请求在等待期间被删掉时抛 `CueStoreError.notFound`。
    func outcome(of request: UUID) async throws -> DeliveryRequest {
        for try await current in store.observe([.deliveryRequests], { try $0.deliveryRequest(request) }) {
            guard let current else { throw CueStoreError.notFound }
            if !current.isOpen { return current }
        }
        throw CancellationError()
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
    /// 主动拉取的令牌先取好，第一次的取令牌不算进往返。超过 `timeout` 没有结果、或结果是失败时抛 `SendError.notDelivered`。
    /// 用过的请求删掉。
    func ping(_ host: String, timeout: Duration = .seconds(60)) async throws -> PingTiming {
        try? await sync?.preparePull()
        let started = ContinuousClock.now
        let request = try await store.requestPing(on: host)
        let written = ContinuousClock.now
        defer { Task { [store] in try? await store.deleteDelivery(request.id) } }
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
    private func result(
        of request: DeliveryRequest.ID, within timeout: Duration
    ) async throws -> (DeliveryRequest, seenAt: (instant: ContinuousClock.Instant, date: Date))? {
        try await withThrowingTaskGroup(of: (DeliveryRequest, seenAt: (instant: ContinuousClock.Instant, date: Date))?.self) { group in
            group.addTask {
                let done = try await self.outcome(of: request)
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

    /// 发送并写一条发送记录；投送失败不写记录，错误原样抛给界面展示。投送成功而记录没写进去时抛 `SendError.unrecorded`。
    /// 发给 Pi 会话不在这里直接发：写本机投送请求、等执行器的结果（见 `sendThroughRequest`）。
    /// `parts`：一并带上的灵感，记在同一条发送记录（或投送请求）里。
    func send(_ storedText: String, to destination: Destination, card: UUID? = nil, parts: [UUID] = []) async throws {
        let content = SendContent(stored: storedText)
        let target: SendTarget
        switch destination {
        #if os(macOS)
        case .pi(let id, let mode):
            try await sendThroughRequest(storedText, to: id, mode: mode, card: card, parts: parts)
            return
        case .app(let selector): target = try await dispatch(content, to: selector, submit: settings.autoSubmit)
        #endif
        case .clipboard: target = try copyToClipboard(content)
        }
        try await recordSend(storedText, to: target, card: card, parts: parts)
    }

    #if os(macOS)
    init(location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, mac: MacDependencies) throws {
        let library = try Self.openLibrary(at: location)
        store = library.store
        images = library.images
        settings = AppSettings(defaults: defaults)
        self.location = location
        (self.sync, syncStatus) = Self.makeSync(sync, store: library.store, location: location)
        hostID = mac.hostID
        wakeNotifications = mac.wakeNotifications
        piStateRecorder = PiStateRecorder(store: library.store, hostID: mac.hostID)
        pi = mac.pi
        channels = mac.channels
        hotkeyBackend = mac.hotkeys
        paths = mac.paths
        terminal = mac.terminal
        locatePi = mac.locatePi
        host = mac.host
        piExtension = PiExtensionManager(installer: mac.installer, settings: settings)
        accessibility = AccessibilityAccess(isTrusted: mac.isAccessibilityTrusted)
        commandLineTool = mac.commandLineTool
        updates = UpdateService(updater: mac.updater)
        historyStore = PiHistoryPersistence(storage: library.store, host: mac.hostID)
    }
    #else
    init(location: LibraryLocation, defaults: UserDefaults, sync: SyncSource, pasteboard: UIPasteboard = .general) throws {
        let library = try Self.openLibrary(at: location)
        store = library.store
        images = library.images
        settings = AppSettings(defaults: defaults)
        self.location = location
        (self.sync, syncStatus) = Self.makeSync(sync, store: library.store, location: location)
        self.pasteboard = pasteboard
    }
    #endif

    /// 资料库是唯一事实源：打不开时不能悄悄换一个空库，也不能带着它往下走——错误交给调用方，启动入口显示失败页
    /// （`UnreadableLibraryView`：原因、重试、导出诊断，不给任何写入入口），不终止进程。
    static func openLibrary(at location: LibraryLocation) throws -> (store: CueStore, images: any CueImageStore) {
        let store = try CueStore(url: location.databaseURL)
        return (store, store.files)
    }

    /// 引擎没能启动：状态写明原因（与启动问题一起），不停在"正在连接"。
    func syncFailedToStart(_ error: any Error) {
        let reason = "同步没能启动：\(error.localizedDescription)"
        syncStatus = .unavailable(reason)
        reportIssue(.syncUnavailable(reason))
    }

    #if os(iOS)
    func post(_ alert: SessionAlert) { sessionAlert = alert }
    #endif

    func setSyncState(_ state: SyncState) {
        syncStatus = state.status
        syncIssues = state.issues
        alertSubscription = state.alerts
    }

    func setConflicts(_ conflicts: [CardConflict]) {
        self.conflicts = conflicts
    }

    func setDeepLink(_ link: DeepLink?) {
        pendingDeepLink = link
    }

    func reportIssue(_ issue: StartupIssue) {
        Self.log.error("\(String(describing: issue), privacy: .public)")
        startupIssues.append(issue)
    }
}
