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
    /// 开出的、已连上桥的假扩展，按 Pi 自己的会话 id：等它非空就是会话在桥上了（起来就记下的话，测试会在连上桥之前往下走）。
    private(set) var extensions: [String: FakeExtension] = [:]
    /// 连上桥的会话报的会话文件，按 Pi 会话 id（收到话才建出来，见 `writeMessage`）
    private(set) var sessionFiles: [String: URL] = [:]
    /// 给了就让开新会话以这个原因失败（Pi 起来就退出时的样子）
    var openFailure: String?
    /// 宿主已创建后，开场消息被扩展明确拒绝。
    var openingRejection: String?
    var openingGate: AsyncStream<Void>?
    var writesMessages = true
    /// 按 Pi 会话 id 装到它每个假扩展上的行为：开出的与结束后被话唤醒重新连上的（`resume`，新进程）都装，会话换了进程照样那样回话
    var behaviors: [String: (FakeExtension) -> Void] = [:]
    /// 接下来的几次唤醒依次以这些错误失败（如会话起得慢、没及时连上桥），用完照常唤醒
    var resumeFailures: [any Error] = []
    private let bridge: PiBridge
    private let socketDirectory: URL
    /// Pi 的会话目录：开的新会话像 Pi 那样一上桥就报出它将来的会话文件 `--demo--/<会话 id>.jsonl`（第一条回答落盘前还不存在）
    private let sessions: URL

    init(bridge: PiBridge, socketDirectory: URL, sessions: URL) {
        self.bridge = bridge
        self.socketDirectory = socketDirectory
        self.sessions = sessions
    }

    func start() {}
    func stop() -> @concurrent @Sendable () async -> Void { {} }
    /// 与 Pi 一样：托管的进程撑得过 App 重启
    var hostedSessionsOutliveApp: Bool { true }

    func resume(_ session: IndexedSession) async throws -> String {
        calls.append(.resume(sessionFile: session.path, directory: session.cwd))
        if !resumeFailures.isEmpty { throw resumeFailures.removeFirst() }
        return try await connect(URL(filePath: session.path).deletingPathExtension().lastPathComponent, cwd: session.cwd).id
    }

    func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> String {
        calls.append(.open(
            directory: directory.path, launchToken: launchToken, name: name, model: model.map { "\($0.provider)/\($0.id)" }, thinking: thinking?.rawValue))
        if let openingGate { for await _ in openingGate { break } }
        try Task.checkCancellation()
        if let openFailure { throw PiHostError.exited(openFailure) }
        let id = "new-\(launchToken)"
        let ext = try await connect(id, cwd: directory.path, sessionFile: sessions.appending(path: "--demo--/\(id).jsonl").path)
        if let openingRejection {
            let previous = ext.onCommand
            ext.onCommand = { connection, command in
                if command["t"] as? String == "send" { return ["ok": false, "error": openingRejection] }
                return previous(connection, command)
            }
        }
        return ext.id
    }

    /// 一个连着桥的会话：假扩展在 socket 目录里监听，桥发现它后返回。`busy` 为 true 时它正在跑一轮；`hosted` 是 CuePad 在后台托管的；
    /// `sessionFile` 是它的会话文件（文件在就算说过话，进程没了时记录留着而不是删掉）。
    @discardableResult
    func connect(
        _ sessionID: String, cwd: String, busy: Bool = false, hosted: Bool = false,
        extensionVersion: Int = PiExtensionBundle.version, sessionFile: String? = nil, seesImages: Bool = true
    ) async throws -> FakeExtension {
        var options = FakeExtension.Options(extensionVersion: extensionVersion, cwd: cwd, hosted: hosted)
        if !seesImages { options.model?.images = false }
        let file = sessionFile.map { URL(filePath: $0) } ?? sessions.appending(path: "--demo--/\(sessionID).jsonl")
        options.sessionFile = file.path
        let ext = FakeExtension(directory: socketDirectory, sessionID: sessionID, options: options)
        if busy { ext.setState(["kind": "thinking"]) }
        let writesMessages = self.writesMessages
        ext.onCommand = { [weak ext] _, command in
            if command["t"] as? String == "end" { ext?.closeAfterReply(bye: "quit") }
            if writesMessages, command["t"] as? String == "send" {
                do { try Self.writeMessage(command, session: sessionID, cwd: cwd, file: file) }
                catch { return ["ok": false, "error": "failed: \(error)"] }
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
    nonisolated private static func writeMessage(_ command: [String: Any], session: String, cwd: String, file: URL) throws {
        let timestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(.now)
        func line(_ object: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(0x0A)
            return data
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try line(["type": "session", "version": 3, "id": session, "timestamp": timestamp, "cwd": cwd]).write(to: file)
        }
        var content: [[String: Any]] = [["type": "text", "text": command["text"] as? String ?? ""]]
        content += (command["images"] as? [[String: Any]] ?? []).map { $0.merging(["type": "image"]) { _, new in new } }
        let message: [String: Any] = [
            // 条目 id 像 Pi 那样每条不同：桥的命令 id 按连接从 c1 数起，唤醒后的新进程会与先前写下的条目撞上
            "type": "message", "id": UUID().uuidString, "timestamp": timestamp,
            "message": ["role": "user", "content": content, "cuepadDelivery": command["deliveryId"] as? String ?? ""],
        ]
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line(message))
    }

}

extension TestApp {
    /// Mac 读完了这个会话的会话文件此刻写下的全部：历史索引的检查点停在文件末尾、修改时间也对上（`PiHistoryCheckpoint.isCurrent`），
    /// 之后不会再为已有的内容写一次摘要。测试替 Mac 写问答（`writePiTranscript`）前先等它：摘要只由读会话文件写，读到的回复总在文件里已有的行之后；
    /// 读得晚的那一次会拿文件里还没有回复的样子盖掉测试写下的。会话文件还没建出来（没收到过话）、不在这台 Mac 上的不用等。
    func historyRead(_ sessionID: String) async throws {
        guard let file = host.sessionFiles[sessionID], FileManager.default.fileExists(atPath: file.path) else { return }
        let store = services.store
        try await eventually("Mac 读完 \(sessionID) 的会话文件") {
            let values = try URL(filePath: file.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let size = values.fileSize, let modified = values.contentModificationDate, let data = try await store.piCheckpoint(of: sessionID) else { return false }
            return try JSONDecoder().decode(PiHistoryCheckpoint.self, from: data).isCurrent(size: UInt64(size), modified: modified)
        }
    }
}

/// 撑不过 App 重启的那几家（Claude Code、Codex 这类靠管道连着 App 的）托管会话的替身：经桥的 `attach` 上桥（各家接入就是这样上桥的），
/// 状态由测试改，命令都受理不做事；`refusal` 有值时像没登录的 Claude Code 那样拒收说的话与命令，原话是它。
final class PipedHostedAgent: AgentRuntime, SessionLink {
    private(set) var messages: [PiMessage] = []
    private(set) var commands: [String] = []
    var refusal: String?
    private let bridge: PiBridge
    private let agent: AgentKind

    init(bridge: PiBridge, agent: AgentKind) {
        self.bridge = bridge
        self.agent = agent
    }

    func start() {}
    func stop() -> @concurrent @Sendable () async -> Void { {} }
    func open(in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?) async throws -> String {
        throw AgentRuntimeError.notInstalled(agent)
    }
    func resume(_ session: IndexedSession) async throws -> String { throw AgentRuntimeError.notInstalled(agent) }
    func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> PiTranscript { throw AgentRuntimeError.notInstalled(agent) }

    /// 一个托管的会话上桥，返回桥上的 id。
    @discardableResult
    func host(_ sessionID: String, state: PiWorkState) -> PiSession.ID {
        var session = PiSession(
            id: "\(sessionID).1", sessionID: sessionID, agent: agent, sessionFile: nil, pid: 1, cwd: URL(filePath: "/work/\(sessionID)"),
            terminal: PiTerminal(), state: state, stateSince: Date())
        session.hosted = true
        bridge.attach(session, via: self)
        return session.id
    }

    func set(_ id: PiSession.ID, _ state: PiWorkState) { bridge.update(id) { $0.state = state } }

    func send(_ message: PiMessage, in id: PiSession.ID) async throws {
        if let refusal { throw PiBridgeError.refused(refusal) }
        messages.append(message)
    }
    func command(_ line: String, deliveryID: String?, in id: PiSession.ID) async throws {
        if let refusal { throw PiBridgeError.refused(refusal) }
        commands.append(line)
    }
    func end(_ id: PiSession.ID) async throws {}
    func abort(_ id: PiSession.ID) async throws {}
    func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws {}
    func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {}
}

extension FakeExtension {
    var received: [String] { commands.compactMap { $0.json["t"] as? String } }

    /// 收到的 `send` 命令，还原成交给桥的消息。
    var messages: [PiMessage] {
        commands.map(\.json).filter { $0["t"] as? String == "send" }.map { json in
            let images = (json["images"] as? [[String: String]] ?? []).map {
                PiImage(mimeType: $0["mimeType"] ?? "", data: Data(base64Encoded: $0["data"] ?? "") ?? Data())
            }
            return PiMessage(text: json["text"] as? String ?? "", images: images, deliveryID: json["deliveryId"] as? String)
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

/// 记下 Cue 推了哪些通知，不碰系统通知中心。
final class RecordingCueNotifier: CueNotifying {
    private(set) var posted: [(title: String, body: String)] = []

    func post(title: String, body: String) async { posted.append((title, body)) }
}

extension AppServices {
    /// 演 App 重开：库与桥都留着，只把启动时那一步（对账、写下在线，`AppServices.launch`）再走一遍。
    func reconcileLaunch() throws { try Self.launch(store, on: hostID, bridge: pi) }
}
#endif
