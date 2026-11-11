#if os(macOS)
import CueStore
@testable import CueBridge
import Foundation
@testable import CuePad

// MARK: 替身

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
    /// 开出的、已连上桥的假扩展，按 Pi 自己的会话 id：等它非空就是会话在桥上了（起来就记下的话，测试会在连上桥之前往下走）。
    private(set) var extensions: [String: FakeExtension] = [:]
    /// 连上桥的会话报的会话文件，按 Pi 会话 id：收到的话（`writesMessages`）与剧本写的会话说的都追加在这里，Mac 读它（第一条写下前还不存在）
    private(set) var sessionFiles: [String: SessionFile] = [:]
    var openFailure: String?
    var openingRejection: String?
    var openingGate: AsyncStream<Void>?
    var writesMessages = true
    /// 按 Pi 会话 id 装到它每个假扩展上的行为：开出的与结束后被话唤醒重新连上的（`resume`，新进程）都装，会话换了进程照样那样回话
    var behaviors: [String: (FakeExtension) -> Void] = [:]
    var resumeFailures: [any Error] = []
    private let bridge: Bridge
    private let socketDirectory: URL
    /// Pi 的会话目录：开的新会话像 Pi 那样一上桥就报出它将来的会话文件 `--demo--/<会话 id>.jsonl`（第一条回答落盘前还不存在）
    private let sessions: URL

    init(bridge: Bridge, socketDirectory: URL, sessions: URL) {
        self.bridge = bridge
        self.socketDirectory = socketDirectory
        self.sessions = sessions
    }

    func start() {}
    func stop() -> @concurrent @Sendable () async -> Void { {} }
    var hostedSessionsOutliveApp: Bool { true }

    func resume(_ session: IndexedSession) async throws -> String {
        calls.append(.resume(sessionFile: session.path, directory: session.cwd))
        if !resumeFailures.isEmpty { throw resumeFailures.removeFirst() }
        return try await connect(URL(filePath: session.path).deletingPathExtension().lastPathComponent, cwd: session.cwd).id
    }

    func open(
        in directory: URL, launchToken: String, name: String?, model: ModelKey?, thinking: ThinkingLevel?
    ) async throws -> String {
        calls.append(.open(
            directory: directory.path, launchToken: launchToken, name: name, model: model.map { "\($0.provider)/\($0.id)" }, thinking: thinking?.rawValue))
        if let openingGate { for await _ in openingGate { break } }
        try Task.checkCancellation()
        if let openFailure { throw PiHostError.exited(openFailure) }
        let id = "new-\(launchToken)"
        let ext = try await connect(id, cwd: directory.path, sessionFile: sessions.appending(path: "--demo--/\(id).jsonl").path, launchToken: launchToken)
        if let openingRejection {
            let previous = ext.onCommand
            ext.onCommand = { connection, command in
                if command["t"] as? String == "send" { return ["ok": false, "error": openingRejection] }
                return previous(connection, command)
            }
        }
        return ext.id
    }

    /// 一个连着桥的会话：假扩展在 socket 目录里监听，桥发现它后返回。`busy` 为 true 时它正在跑一轮；
    /// `sessionFile` 是它的会话文件（文件在就算说过话，进程没了时记录留着而不是删掉）。
    @discardableResult
    func connect(
        _ sessionID: String, cwd: String, busy: Bool = false,
        extensionVersion: Int = PiExtensionBundle.version, sessionFile: String? = nil, seesImages: Bool = true, launchToken: String? = nil
    ) async throws -> FakeExtension {
        var options = FakeExtension.Options(extensionVersion: extensionVersion, cwd: cwd)
        options.launchToken = launchToken
        if !seesImages { options.model?.images = false }
        let file = SessionFile(url: sessionFile.map { URL(filePath: $0) } ?? sessions.appending(path: "--demo--/\(sessionID).jsonl"), sessionID: sessionID, cwd: cwd)
        options.sessionFile = file.url.path
        let ext = FakeExtension(directory: socketDirectory, sessionID: sessionID, options: options)
        if busy { ext.setState(["kind": "thinking"]) }
        let writesMessages = self.writesMessages
        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "end" { ext?.closeAfterReply(bye: "quit") }
            if writesMessages, command["t"] as? String == "send" {
                do {
                    try file.user(
                        command["text"] as? String ?? "", images: command["images"] as? [[String: Any]] ?? [], delivery: command["deliveryId"] as? String)
                } catch { return ["ok": false, "error": "failed: \(error)"] }
            }
            return ["ok": true]
        }
        behaviors[sessionID]?(ext)
        try bridge.start()
        try ext.start()
        try await eventually("桥连上 \(sessionID)") { bridge.session(id: ext.id) != nil }
        extensions[sessionID] = ext
        sessionFiles[sessionID] = file
        return ext
    }
}

/// 撑不过 App 重启的那几家（Claude Code、Codex 这类靠管道连着 App 的）托管会话的替身：经桥的 `attach` 上桥（各家接入就是这样上桥的），
/// 状态由测试改，命令都受理不做事；`refusal` 有值时像没登录的 Claude Code 那样拒收说的话与命令，原话是它。
final class PipedHostedAgent: AgentRuntime, SessionLink {
    private(set) var messages: [SessionMessage] = []
    private(set) var commands: [String] = []
    var refusal: String?
    private let bridge: Bridge
    private let agent: AgentKind

    init(bridge: Bridge, agent: AgentKind) {
        self.bridge = bridge
        self.agent = agent
    }

    func start() {}
    func stop() -> @concurrent @Sendable () async -> Void { {} }
    func open(in directory: URL, launchToken: String, name: String?, model: ModelKey?, thinking: ThinkingLevel?) async throws -> String {
        throw AgentRuntimeError.notInstalled(agent)
    }
    func resume(_ session: IndexedSession) async throws -> String { throw AgentRuntimeError.notInstalled(agent) }
    func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> SessionTranscript { throw AgentRuntimeError.notInstalled(agent) }

    @discardableResult
    func host(_ sessionID: String, state: WorkState) -> Session.ID {
        let session = Session(
            id: "\(sessionID).1", sessionID: sessionID, agent: agent, sessionFile: nil, pid: 1, cwd: URL(filePath: "/work/\(sessionID)"),
            terminal: TerminalIdentity(), state: state, stateSince: Date())
        bridge.attach(session, via: self)
        return session.id
    }

    func set(_ id: Session.ID, _ state: WorkState) { bridge.update(id) { $0.state = state } }

    func send(_ message: SessionMessage, in id: Session.ID) async throws {
        if let refusal { throw BridgeError.refused(refusal) }
        messages.append(message)
    }
    func command(_ line: String, deliveryID: String?, in id: Session.ID) async throws {
        if let refusal { throw BridgeError.refused(refusal) }
        commands.append(line)
    }
    func end(_ id: Session.ID) async throws {}
    func abort(_ id: Session.ID) async throws {}
    func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws {}
    func configure(_ config: SessionConfig, in id: Session.ID) async throws {
        guard config.fast == nil else { throw BridgeError.unsupported }
    }
}

extension FakeExtension {
    var received: [String] { commands.compactMap { $0.json["t"] as? String } }

    var messages: [SessionMessage] {
        commands.map(\.json).filter { $0["t"] as? String == "send" }.map { json in
            let images = (json["images"] as? [[String: String]] ?? []).map {
                MessageImage(mimeType: $0["mimeType"] ?? "", data: Data(base64Encoded: $0["data"] ?? "") ?? Data())
            }
            return SessionMessage(text: json["text"] as? String ?? "", images: images, deliveryID: json["deliveryId"] as? String)
        }
    }
}

/// 更新器替身：检查一次就"找到更新、你点了安装"，像 Sparkle 一样在退出重启前问一次要不要推迟（`AppUpdater.postponeRelaunch`），
/// 不推迟或推迟后被放行时记下装了几次。
final class FakeUpdater: AppUpdater {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = true
    var postponeRelaunch: ((@escaping () -> Void) -> Bool)?
    private(set) var installs = 0

    func checkForUpdates() {
        let install: () -> Void = { [weak self] in self?.installs += 1 }
        if postponeRelaunch?(install) != true { install() }
    }

    func checkForUpdatesInBackground() { checkForUpdates() }
}

final class RecordingCueNotifier: CueNotifying {
    private(set) var posted: [(title: String, body: String)] = []

    func post(title: String, body: String) async { posted.append((title, body)) }
}

extension AppServices {
    func reconcileLaunch() throws { try Self.launch(store, on: hostID, bridge: bridge) }
}
#endif
