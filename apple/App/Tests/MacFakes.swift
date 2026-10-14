#if os(macOS)
import CueStore
@testable import CuePi
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

/// Pi 的接入替身：记下被要求接着、开哪个会话，不真启动 Pi：被托管的会话由一个假扩展连上真桥（与终端里的 Pi 一样经 socket），
/// 收到结束命令就像 Pi 那样告别退出。
final class RecordingHost: AgentRuntime {
    enum Call: Equatable {
        case resume(sessionFile: String, directory: String)
        case open(directory: String, launchToken: String, name: String? = nil, model: String? = nil, thinking: String? = nil)
    }

    private(set) var calls: [Call] = []
    /// 已连上桥的假扩展，按 Pi 自己的会话 id。
    private(set) var extensions: [String: FakeExtension] = [:]
    /// 给了就让开新会话以这个原因失败（Pi 起来就退出时的样子）
    var openFailure: String?
    private let bridge: PiBridge
    private let socketDirectory: URL

    init(bridge: PiBridge, socketDirectory: URL) {
        self.bridge = bridge
        self.socketDirectory = socketDirectory
    }

    func start() {}
    func stop() -> @concurrent @Sendable () async -> Void { {} }

    func resume(_ session: IndexedSession) async throws -> String {
        calls.append(.resume(sessionFile: session.path, directory: session.cwd))
        return try await connect(URL(filePath: session.path).deletingPathExtension().lastPathComponent, cwd: session.cwd).id
    }

    func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> String {
        calls.append(.open(
            directory: directory.path, launchToken: launchToken, name: name, model: model.map { "\($0.provider)/\($0.id)" }, thinking: thinking?.rawValue))
        if let openFailure { throw PiHostError.exited(openFailure) }
        return try await connect("new-\(launchToken)", cwd: directory.path).id
    }

    /// 一个连着桥的会话：假扩展在 socket 目录里监听，桥发现它后返回。`busy` 为 true 时它正在跑一轮。
    @discardableResult
    func connect(
        _ sessionID: String, cwd: String, busy: Bool = false, protocolVersion: Int = PiWire.protocolVersion
    ) async throws -> FakeExtension {
        let ext = FakeExtension(directory: socketDirectory, sessionID: sessionID, options: .init(protocolVersion: protocolVersion, cwd: cwd))
        if busy { ext.setState(["kind": "thinking"]) }
        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "end" { DispatchQueue.global().async { ext?.close(bye: "quit") } }
            return ["ok": true, "delivered": "immediate"]
        }
        try bridge.start()
        try ext.start()
        extensions[sessionID] = ext
        try await eventually("bridge.session(id: ext.id) != nil") { bridge.session(id: ext.id) != nil }
        guard bridge.session(id: ext.id) != nil else { throw ConnectTimeout(sessionID: sessionID) }
        return ext
    }

    struct ConnectTimeout: Error { var sessionID: String }
}

extension FakeExtension {
    /// 收到的命令种类，按到达顺序。
    var received: [String] { commands.compactMap { $0.json["t"] as? String } }

    /// 收到的 `send` 命令，还原成交给桥的消息。
    var messages: [PiMessage] {
        commands.map(\.json).filter { $0["t"] as? String == "send" }.map { json in
            let images = (json["images"] as? [[String: String]] ?? []).map {
                PiImage(mimeType: $0["mimeType"] ?? "", data: Data(base64Encoded: $0["data"] ?? "") ?? Data())
            }
            return PiMessage(
                text: json["text"] as? String ?? "", images: images,
                whenBusy: (json["deliverAs"] as? String).flatMap(PiQueueMode.init(rawValue:)), deliveryID: json["deliveryId"] as? String)
        }
    }
}

/// 记下 Cue 推了哪些通知，不碰系统通知中心。
final class RecordingCueNotifier: CueNotifying {
    var onOpen: (() -> Void)?
    private(set) var posted: [(title: String, body: String)] = []

    func post(id: UUID, title: String, body: String) async { posted.append((title, body)) }
}

final class RecordingWindow: ShellWindow {
    var isVisible = true
    var isFocused = true
    private(set) var events: [String] = []

    func show() { events.append("show"); isVisible = true; isFocused = true }
    func hide() { events.append("hide"); isVisible = false; isFocused = false }
}
#endif
