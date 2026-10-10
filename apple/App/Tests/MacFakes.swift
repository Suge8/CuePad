#if os(macOS)
import CuePi
import CueStore
import Foundation
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

/// 记录调用的发送通道；不碰真实 Pi 与剪贴板。
final class FakeChannels: SendChannels {
    enum Call: Equatable {
        case send(PiMessage, String)
        case answer(PiAnswerValue, String, String)
        case configure(PiModelKey?, PiThinkingLevel?, String?, String)
        case command(String, PiQueueMode?, String)
        case abort(String)
        case copy(ClipboardContent)
    }

    var calls: [Call] = []
    var sessions: [String: PiSessionInfo] = [:]
    var sendError: (any Error)?

    func piSession(_ id: String) -> PiSessionInfo? { sessions[id] }
    /// Pi 自己的会话 id → 桥上的会话 id
    var bridgeIDs: [String: String] = [:]
    func piSessionID(forSession sessionID: String) -> String? { bridgeIDs[sessionID] }
    func send(_ message: PiMessage, to id: String) async throws {
        if let sendError { throw sendError }
        calls.append(.send(message, id))
    }
    func answer(_ answer: PiAnswerValue, to prompt: String, in id: String) async throws { calls.append(.answer(answer, prompt, id)) }
    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: String) async throws {
        calls.append(.configure(model, thinking, name, id))
    }
    func command(_ line: String, whenBusy: PiQueueMode?, in id: String) async throws { calls.append(.command(line, whenBusy, id)) }
    func abort(in id: String) async throws { calls.append(.abort(id)) }
    func copy(_ content: ClipboardContent) throws { calls.append(.copy(content)) }
}

final class RecordingWindow: ShellWindow {
    var isVisible = true
    var isFocused = true
    private(set) var events: [String] = []

    func show() { events.append("show"); isVisible = true; isFocused = true }
    func hide() { events.append("hide"); isVisible = false; isFocused = false }
}
#endif
