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
/// 发送记录也只在这里写。本文件的公开形状由主会话冻结：界面 Worker 与服务 Worker 并行开发，需要增改成员先找主会话。
@MainActor @Observable
final class AppServices {
    static let bundleID = "com.sugeh.cuepad"
    static let log = Logger(subsystem: bundleID, category: "services")

    let store: CueStore
    let images: any CueImageStore
    #if os(macOS)
    let pi: PiBridge
    #endif

    /// 设备本地偏好（主题、快捷键、自动发送、当前项目）。
    let settings: AppSettings
    /// 启动期间没能完成的事；界面据此提示，不静默。
    private(set) var startupIssues: [StartupIssue] = []
    /// 本次启动从 Electron 旧库导入的结果；没有导入（已导入过或没有旧库）为 nil。
    private(set) var legacyImportReport: ImportReport?

    @ObservationIgnored let location: LibraryLocation

    /// iCloud 同步引擎；隔离模式与测试为 nil。状态、问题与冲突见下，动作见 `AppServices+Sync`。
    @ObservationIgnored let sync: (any SyncControlling)?
    private(set) var syncStatus: SyncStatus = .idle
    private(set) var syncIssues: [SyncIssue] = []
    /// 待用户处理的正文冲突（同一张卡离线并发编辑产生的副本）。
    private(set) var conflicts: [CardConflict] = []

    /// 小组件、分享扩展打开 App 的链接，界面处理后调用 `consumeDeepLink()`。
    private(set) var pendingDeepLink: DeepLink?

    @ObservationIgnored var tasks: [Task<Void, Never>] = []
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
    /// Pi 历史首次回填是否已完成。
    private(set) var piHistoryBackfilled = false
    /// 主窗口显隐；通用投送前后与全局快捷键都经它。
    @ObservationIgnored var windowShell: WindowShell?

    @ObservationIgnored let channels: any SendChannels
    @ObservationIgnored let paths: PiPaths
    @ObservationIgnored let terminal: PiTerminalJumper
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

    /// 发往哪里。正文一律是存储格式（变量已填、编号已排），图片引用由这里解析成真实图片。
    enum Destination: Equatable {
        #if os(macOS)
        /// 直接发进 Pi 会话；`whenBusy` 为 nil 时会话忙则报错，否则插话或排队。
        case pi(CuePi.PiSession.ID, whenBusy: PiQueueMode?)
        /// 只把文字放进 Pi 输入框（含图片时由调用方禁用此项）。
        case piInput(CuePi.PiSession.ID)
        /// 通用投送：剪贴板 + 激活目标 + 定向粘贴，可选回车。
        case app(TargetSelector, submit: Bool)
        #endif
        /// 只复制到剪贴板。
        case clipboard
    }

    /// 发到 Mac 的发送方式。原始值是 `DeliveryRequest.mode`，Mac 执行器按它选择 Pi 的发送方式。
    nonisolated enum MacSendMode: String, CaseIterable, Hashable, Sendable {
        /// 直接发送（会话空闲时）。
        case send
        /// 插话：打断正在进行的这一轮。
        case steer
        /// 排队：这一轮结束后再发。
        case followUp
        /// 只放进 Pi 的输入框，不发送；只有文字。
        case paste
    }

    /// 发到 Mac：写一条投送请求，交给运行该 Pi 会话的那台 Mac（取自会话的 `hostID`）执行；
    /// 那台 Mac 执行后写回结果并记发送记录，这里不记。
    @discardableResult
    func requestMacDelivery(
        _ storedText: String, to session: PiSessionState, mode: MacSendMode, card: UUID? = nil, task: UUID? = nil
    ) async throws -> DeliveryRequest {
        try await store.requestDelivery(
            storedText, to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID,
            mode: mode.rawValue, card: card, task: task)
    }

    /// 发送并写一条发送记录；失败不写记录，错误原样抛给界面展示。
    func send(_ storedText: String, to destination: Destination, card: UUID? = nil, task: UUID? = nil) async throws {
        let target = try await deliver(SendContent(stored: storedText), to: destination)
        await recordSend(storedText, to: target, card: card, task: task)
    }

    #if os(macOS)
    convenience init() {
        let location = LibraryLocation.standard
        self.init(
            location: location, defaults: location.makeDefaults(),
            sync: { Self.makeSync(store: $0, location: location) }, mac: .live(bundleID: Self.bundleID))
    }

    init(location: LibraryLocation, defaults: UserDefaults, sync: (CueStore) -> (any SyncControlling)? = { _ in nil }, mac: MacDependencies) {
        let library = Self.openLibrary(at: location)
        store = library.store
        images = library.images
        settings = AppSettings(defaults: defaults)
        self.location = location
        self.sync = sync(library.store)
        hostID = mac.hostID
        wakeNotifications = mac.wakeNotifications
        piStateRecorder = PiStateRecorder(store: library.store, hostID: mac.hostID)
        pi = mac.pi
        channels = mac.channels
        hotkeyBackend = mac.hotkeys
        paths = mac.paths
        terminal = mac.terminal
        piExtension = PiExtensionManager(installer: mac.installer, settings: settings)
        accessibility = AccessibilityAccess(isTrusted: mac.isAccessibilityTrusted)
        historyStore = PiHistoryPersistence(storage: mac.historyStorage ?? library.store)
    }
    #else
    convenience init() {
        let location = LibraryLocation.standard
        self.init(location: location, defaults: location.makeDefaults(), sync: { Self.makeSync(store: $0, location: location) })
    }

    init(
        location: LibraryLocation, defaults: UserDefaults, sync: (CueStore) -> (any SyncControlling)? = { _ in nil },
        pasteboard: UIPasteboard = .general
    ) {
        let library = Self.openLibrary(at: location)
        store = library.store
        images = library.images
        settings = AppSettings(defaults: defaults)
        self.location = location
        self.sync = sync(library.store)
        self.pasteboard = pasteboard
    }
    #endif

    /// 资料库是唯一事实源：打不开时不能悄悄换一个空库，直接终止并说明原因。
    private static func openLibrary(at location: LibraryLocation) -> (store: CueStore, images: any CueImageStore) {
        do {
            let store = try CueStore(url: location.databaseURL)
            return (store, StoreImages(store: store, attachments: location.attachmentsDirectory))
        } catch {
            preconditionFailure("无法打开资料库 \(location.databaseURL.path)：\(error)")
        }
    }

    func setSyncState(status: SyncStatus, issues: [SyncIssue]) {
        syncStatus = status
        syncIssues = issues
    }

    func setConflicts(_ conflicts: [CardConflict]) {
        self.conflicts = conflicts
    }

    func setDeepLink(_ link: DeepLink?) {
        pendingDeepLink = link
    }

    func finishLegacyImport(_ report: ImportReport) {
        legacyImportReport = report
    }

    #if os(macOS)
    func finishPiHistoryBackfill() {
        piHistoryBackfilled = true
    }
    #endif

    func reportIssue(_ issue: StartupIssue) {
        Self.log.error("\(String(describing: issue), privacy: .public)")
        startupIssues.append(issue)
    }
}
