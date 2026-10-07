#if os(macOS)
import CueDispatch
import CuePi
import CueStore
import Foundation
import SQLite3
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

/// 记下后台托管被要求恢复、开哪个会话，不真启动 Pi：托管的会话随即"连上"发送通道替身。
final class RecordingHost: PiHosting {
    enum Call: Equatable {
        case resume(sessionFile: String, directory: String)
        case open(directory: String, launchToken: String)
        case end(String)
    }

    private(set) var calls: [Call] = []
    let channels: FakeChannels

    init(channels: FakeChannels) { self.channels = channels }

    func start() {}
    func closeAll() -> @concurrent @Sendable () async -> Void { {} }

    func resume(sessionFile: URL, in directory: URL, executable: URL) async throws -> String {
        calls.append(.resume(sessionFile: sessionFile.path, directory: directory.path))
        return connect(sessionFile.deletingPathExtension().lastPathComponent)
    }

    func end(_ id: String) async throws { calls.append(.end(id)) }

    func open(in directory: URL, launchToken: String, executable: URL) async throws -> String {
        calls.append(.open(directory: directory.path, launchToken: launchToken))
        return connect("new-\(launchToken)")
    }

    private func connect(_ sessionID: String) -> String {
        let id = "\(sessionID).900"
        channels.bridgeIDs[sessionID] = id
        channels.sessions[id] = PiSessionInfo(target: SendTarget(kind: .piSession, name: sessionID, ref: sessionID), isBusy: false)
        return id
    }
}

/// 记录调用的发送通道；不碰真实 Pi、剪贴板和其他应用。
final class FakeChannels: SendChannels {
    enum Call: Equatable {
        case send(PiMessage, String)
        case paste(String, String)
        case answer(PiPromptAnswer, String, String)
        case configure(PiModelRef?, String?, String)
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
    func answer(_ answer: PiPromptAnswer, to prompt: String, in id: String) async throws { calls.append(.answer(answer, prompt, id)) }
    func configure(model: PiModelRef?, thinking: String?, in id: String) async throws { calls.append(.configure(model, thinking, id)) }
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
