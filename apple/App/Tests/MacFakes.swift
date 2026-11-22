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

final class RecordingHost: AgentRuntime {
    enum Call: Equatable {
        case resume(sessionFile: String, directory: String)
        case open(directory: String, launchToken: String, name: String? = nil, model: String? = nil, thinking: String? = nil)
    }

    private(set) var calls: [Call] = []
    private(set) var extensions: [String: FakeExtension] = [:]
    private(set) var sessionFiles: [String: SessionFile] = [:]
    var openFailure: String?
    var openingRejection: String?
    var openingGate: AsyncStream<Void>?
    var writesMessages = true
    var behaviors: [String: (FakeExtension) -> Void] = [:]
    var resumeFailures: [any Error] = []
    private let bridge: Bridge
    private let socketDirectory: URL
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

    @discardableResult
    func connect(
        _ sessionID: String, cwd: String, busy: Bool = false, since: Date? = nil,
        extensionVersion: Int = PiExtensionBundle.version, sessionFile: String? = nil, seesImages: Bool = true, supportsFast: Bool = false,
        launchToken: String? = nil
    ) async throws -> FakeExtension {
        var options = FakeExtension.Options(extensionVersion: extensionVersion, cwd: cwd)
        options.launchToken = launchToken
        options.commands = ["compact", "greet", "shout"].map { FakeExtension.WireCommand(name: $0, description: nil) }
        if !seesImages { options.model?.images = false }
        options.model?.supportsFast = supportsFast
        let file = SessionFile(url: sessionFile.map { URL(filePath: $0) } ?? sessions.appending(path: "--demo--/\(sessionID).jsonl"), sessionID: sessionID, cwd: cwd)
        options.sessionFile = file.url.path
        let ext = FakeExtension(directory: socketDirectory, sessionID: sessionID, options: options)
        if busy || since != nil {
            ext.setState(["kind": busy ? "thinking" : "idle"].merging(since.map { ["since": Int($0.stored)] } ?? [:]) { $1 })
        }
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
        var session = Session(
            id: "\(sessionID).1", sessionID: sessionID, agent: agent, sessionFile: nil, pid: 1, cwd: URL(filePath: "/work/\(sessionID)"),
            state: state, stateSince: Date())
        session.commands = [SlashCommand(name: "review", summary: nil, source: .known(.builtin))]
        bridge.attach(session, via: self)
        return session.id
    }

    func set(_ id: Session.ID, _ state: WorkState) { bridge.update(id) { $0.state = state } }

    func send(_ message: SessionMessage, in id: Session.ID) async throws {
        if let refusal { throw BridgeError.refused(refusal) }
        messages.append(message)
        if let opener = message.opener { bridge.update(id) { $0.turnOpener = opener } }
    }
    func command(_ line: String, opener: TurnOpener?, in id: Session.ID) async throws {
        if let refusal { throw BridgeError.refused(refusal) }
        commands.append(line)
    }
    func end(_ id: Session.ID) async throws {}
    func abort(_ id: Session.ID) async throws {}
    func answer(_ answer: AnswerValue, to promptID: String, in id: Session.ID) async throws {}
    func configure(_ config: SessionConfig, in id: Session.ID) async throws {}
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
