import Foundation
import Observation
import CueStore
import CueEditor
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
    @ObservationIgnored lazy var hotkey = GlobalHotkey(backend: hotkeyBackend) { [weak self] in
        self?.windowShell?.toggleFromHotkey()
    }
    @ObservationIgnored var tasks: [Task<Void, Never>] = []
    #endif

    nonisolated enum StartupIssue: Equatable {
        case legacyImportFailed(String)
        case globalShortcutUnavailable(String)
        #if os(macOS)
        case piBridgeUnavailable(String)
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

    /// 发送并写一条发送记录；失败不写记录，错误原样抛给界面展示。
    func send(_ storedText: String, to destination: Destination, card: UUID? = nil, task: UUID? = nil) async throws {
        let target = try await deliver(SendContent(stored: storedText), to: destination)
        await recordSend(storedText, to: target, card: card, task: task)
    }

    #if os(macOS)
    convenience init() {
        self.init(location: .standard, defaults: .standard, mac: .live(bundleID: Self.bundleID))
    }

    init(location: LibraryLocation, defaults: UserDefaults, mac: MacDependencies) {
        let library = Self.openLibrary(at: location)
        store = library.store
        images = library.images
        settings = AppSettings(defaults: defaults)
        self.location = location
        pi = mac.pi
        channels = mac.channels
        hotkeyBackend = mac.hotkeys
        paths = mac.paths
        terminal = mac.terminal
        piExtension = PiExtensionManager(installer: mac.installer, settings: settings)
        accessibility = AccessibilityAccess(isTrusted: mac.isAccessibilityTrusted)
        historyStore = PiHistoryPersistence(store: library.store)
    }
    #else
    convenience init() {
        self.init(location: .standard, defaults: .standard)
    }

    init(location: LibraryLocation, defaults: UserDefaults) {
        let library = Self.openLibrary(at: location)
        store = library.store
        images = library.images
        settings = AppSettings(defaults: defaults)
        self.location = location
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
