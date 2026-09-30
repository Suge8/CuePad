#if os(macOS)
import CoreGraphics
import CueDispatch
import CuePi
import CueStore
import Foundation
import ImageIO
import SQLite3
import UniformTypeIdentifiers
@testable import CuePad

// MARK: 替身

/// 内存热键：同一组合只能注册一次，与系统行为一致。
final class InMemoryHotkeys: HotkeyBackend {
    private var handles: [HotkeyHandle: Shortcut] = [:]
    private var next: HotkeyHandle = 1
    var active: Set<Shortcut> { Set(handles.values) }

    func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) throws -> HotkeyHandle {
        guard !active.contains(shortcut) else { throw HotkeyError.occupied(shortcut) }
        defer { next += 1 }
        handles[next] = shortcut
        return next
    }

    func unregister(_ handle: HotkeyHandle) { handles[handle] = nil }
}

/// 记录调用的发送通道；不碰真实 Pi、剪贴板和其他应用。
final class FakeChannels: SendChannels {
    enum Call: Equatable {
        case send(PiMessage, String)
        case paste(String, String)
        case preflight(TargetSelector)
        case dispatch(Payload, TargetSelector, submit: Bool)
        case copy(Payload)
    }

    var calls: [Call] = []
    var sessions: [String: PiSessionInfo] = [:]
    var preflightError: (any Error)?
    var dispatchError: (any Error)?
    var app = AppInfo(pid: 42, bundleID: "com.example.editor", name: "Editor")

    func piSession(_ id: String) -> PiSessionInfo? { sessions[id] }
    /// Pi 自己的会话 id → 桥上的会话 id
    var bridgeIDs: [String: String] = [:]
    func piSessionID(forSession sessionID: String) -> String? { bridgeIDs[sessionID] }
    func send(_ message: PiMessage, to id: String) async throws { calls.append(.send(message, id)) }
    func paste(_ text: String, into id: String) async throws { calls.append(.paste(text, id)) }
    func runningApps() -> [AppInfo] { [] }
    func lastFrontmost() -> AppInfo? { nil }

    func preflight(_ selector: TargetSelector) async throws {
        calls.append(.preflight(selector))
        if let preflightError { throw preflightError }
    }

    func dispatch(_ payload: Payload, to selector: TargetSelector, submit: Bool) async throws -> AppInfo {
        calls.append(.dispatch(payload, selector, submit: submit))
        if let dispatchError { throw dispatchError }
        return app
    }

    func copy(_ payload: Payload) throws { calls.append(.copy(payload)) }
}

final class RecordingWindow: ShellWindow {
    var isVisible = true
    var isFocused = true
    private(set) var events: [String] = []

    func show() { events.append("show"); isVisible = true; isFocused = true }
    func hide() { events.append("hide"); isVisible = false; isFocused = false }
}

// MARK: 装配

/// 一次"App 启动"：临时库目录 + 独立 UserDefaults + 替身通道。`relaunch()` 用同一批目录再起一个实例。
final class Rig {
    static let hostID = "mac-test"
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "cuepad-app-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    /// 偏好放在临时目录里（路径型套件），随目录一起删除，不在 ~/Library/Preferences 里留文件。
    var suite: String { directory.appending(path: "preferences").path }
    let channels = FakeChannels()
    let sync = FakeSync()
    let wakeCenter = NotificationCenter()
    let hotkeys = InMemoryHotkeys()
    let window = RecordingWindow()
    let legacy: URL?
    let historyStorage: (any PiIndexStorage)?
    private(set) var services: AppServices!

    init(legacy: URL? = nil, historyStorage: (any PiIndexStorage)? = nil) {
        self.legacy = legacy
        self.historyStorage = historyStorage
        services = makeServices()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var defaults: UserDefaults {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return UserDefaults(suiteName: suite)!
    }
    var piPaths: PiPaths {
        PiPaths(agentDirectory: directory.appending(path: "pi-agent"), socketDirectory: directory.appending(path: "sock"))
    }

    @discardableResult
    func relaunch() -> AppServices {
        services.cancelBackgroundWork()
        services = makeServices()
        return services
    }

    /// 没有旧库：隔离目录；有旧库：把它挂到"应用支持目录"里 Electron 版的位置（旧库位置只由这条规则决定）。
    private func location() -> LibraryLocation {
        if let legacy {
            let support = directory.appending(path: "support", directoryHint: .isDirectory)
            let electron = support.appending(path: "CuePad/cuepad.db")
            try! FileManager.default.createDirectory(at: electron.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: electron)
            try! FileManager.default.createSymbolicLink(at: electron, withDestinationURL: legacy)
            return try! LibraryLocation.resolve(environment: [:], base: .applicationSupport(support))
        }
        return try! LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: directory.appending(path: "Library").path])
    }

    private func makeServices() -> AppServices {
        let mac = MacDependencies(
            pi: PiBridge(socketDirectory: piPaths.socketDirectory),
            channels: channels,
            hotkeys: hotkeys,
            paths: piPaths,
            installer: PiExtensionInstaller(paths: piPaths, locator: PiExecutableLocator(searchDirectories: [directory.appending(path: "bin")])),
            terminal: PiTerminalJumper(),
            isAccessibilityTrusted: { true },
            historyStorage: historyStorage,
            hostID: Rig.hostID,
            wakeNotifications: wakeCenter)
        let sync = self.sync
        let services = AppServices(location: location(), defaults: defaults, sync: { _ in sync }, mac: mac)
        services.windowShell = WindowShell(window: window)
        return services
    }
}

// MARK: 夹具

/// Electron 版旧库（schema 取其迁移最终状态的必要列）。
func makeLegacyDatabase(settings: [String: String] = [:], at url: URL? = nil) throws -> URL {
    let url = url ?? FileManager.default.temporaryDirectory.appending(path: "cuepad-legacy-\(UUID().uuidString).db")
    let settingRows = settings.map { "INSERT INTO app_settings VALUES ('\($0.key)','\($0.value)',1,2);" }.joined()
    let sql = """
        CREATE TABLE projects (id INTEGER PRIMARY KEY, name TEXT, icon TEXT, color TEXT NOT NULL,
          sort_order INTEGER NOT NULL DEFAULT 0, is_pinned INTEGER NOT NULL DEFAULT 0, deleted_at INTEGER,
          delete_source TEXT, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        CREATE TABLE cards (id INTEGER PRIMARY KEY, project_id INTEGER, title TEXT, body TEXT,
          sort_order INTEGER NOT NULL DEFAULT 0, is_favorite INTEGER NOT NULL DEFAULT 0,
          numbering TEXT NOT NULL DEFAULT 'none', deleted_at INTEGER, delete_source TEXT,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT NOT NULL, color TEXT, deleted_at INTEGER,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        CREATE TABLE card_tags (card_id INTEGER NOT NULL, tag_id INTEGER NOT NULL, created_at INTEGER NOT NULL);
        CREATE TABLE tasks (id INTEGER PRIMARY KEY, content TEXT NOT NULL, project_id INTEGER,
          sort_order INTEGER NOT NULL DEFAULT 0, completed_at INTEGER,
          created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        CREATE TABLE app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);
        INSERT INTO projects VALUES (1,'Flow','target','#4f8ce8',2,1,NULL,NULL,1000,2000);
        INSERT INTO projects VALUES (2,'Career','book','#e2679c',1,0,NULL,NULL,1100,2100);
        INSERT INTO cards VALUES (10,1,'Todo','line one',1,0,'none',NULL,NULL,3000,4000);
        INSERT INTO tasks VALUES (20,'first',1,1,NULL,6000,6000);
        \(settingRows)
        """
    var handle: OpaquePointer?
    defer { sqlite3_close(handle) }
    guard sqlite3_open(url.path, &handle) == SQLITE_OK, sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
        throw FixtureError()
    }
    return url
}

struct FixtureError: Error {}
#endif
