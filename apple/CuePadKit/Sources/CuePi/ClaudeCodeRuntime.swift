#if os(macOS)
import CueStore
import Darwin
import Foundation
import OSLog

/// Claude Code 的接入：终端里的会话经钩子（`AgentHookServer`）上报、经它的收件箱 socket 说话、经挡着的钩子作答（`ClaudeTerminalSession`）；
/// 后台托管的会话是 CuePad 起的 stream-json 进程（`ClaudeHostedSession`）。
///
/// - 终端会话：第一次钩子调用时上桥，id 是 `<会话 id>.<进程 pid>`；同一进程里 /clear、/resume 换了会话，旧的下桥、新的上桥；
///   进程退出（kqueue）时下桥。CuePad 启动时已经在跑的会话（还没触发钩子）从 `claude agents --json` 补上。
/// - 托管会话：开新会话（`--session-id`）与接着已结束的会话（`--resume`）；接着之前先确认它没开在别处（终端里开着时两边会各写各的）。
///   同一会话在终端里打开时托管的让出（空闲即退，在跑一轮就做完再退）。
@MainActor
public final class ClaudeCodeRuntime: AgentRuntime {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "claude")
    private let bridge: PiBridge
    private let paths: AgentPaths
    private let hooks: AgentHookServer
    private let locator: ExecutableLocator
    private let idleLimit: Duration
    private let endTimeout: Duration
    private var terminals: [PiSession.ID: ClaudeTerminalSession] = [:]
    /// 每个终端进程一个退出监视；进程里此刻的会话见 `terminals`
    private var exitWatchers: [Int32: ProcessExitWatcher] = [:]
    private var hosted: [String: ClaudeHostedSession] = [:]  // 会话 id → 托管进程

    public init(
        bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer, locator: ExecutableLocator = .standard,
        idleLimit: Duration = .seconds(30 * 60), endTimeout: Duration = .seconds(10)
    ) {
        self.bridge = bridge
        self.paths = paths
        self.hooks = hooks
        self.locator = locator
        self.idleLimit = idleLimit
        self.endTimeout = endTimeout
    }

    private var home: URL { paths.home(of: .claudeCode) }

    /// 给 `claude` 的环境：本进程的，加上 `paths` 里指定的（隔离的配置目录等）。不自己补 `CLAUDE_CONFIG_DIR`：
    /// 设了它 Claude Code 就到那个目录里找 `.claude.json`，与没设时的 `~/.claude.json` 不是一份。
    private var environment: [String: String] { ProcessInfo.processInfo.environment.merging(paths.environment) { $1 } }

    public func start() throws {
        hooks.handle(.claudeCode) { [weak self] call in self?.received(call) }
        Task { await discover() }
    }

    public func stop() -> @concurrent @Sendable () async -> Void {
        let processes = hosted.values.map(\.process)
        for session in hosted.values { session.close() }
        return { for process in processes { _ = await process.exited() } }
    }

    public func open(in directory: URL, launchToken: String) async throws -> PiSession.ID {
        let sessionID = UUID().uuidString.lowercased()
        return try await launch(sessionID: sessionID, arguments: ["--session-id", sessionID], in: directory, launchToken: launchToken)
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        try await configure(
            opened: try await open(in: directory, launchToken: launchToken), name: name, model: model, thinking: thinking, on: bridge)
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let running = hosted[session.id], let id = running.id { return id }
        if bridge.sessions.contains(where: { $0.agent == .claudeCode && $0.sessionID == session.id && !$0.hosted }) {
            throw AgentRuntimeError.openElsewhere
        }
        // 还没触发过钩子的终端会话（钩子没装、或 CuePad 之后才启动）桥上没有，问 Claude Code 自己
        if try await running().contains(where: { $0.sessionID == session.id }) { throw AgentRuntimeError.openElsewhere }
        let directory = URL(filePath: session.cwd, directoryHint: .isDirectory)
        return try await launch(sessionID: session.id, arguments: ["--resume", session.id], in: directory, launchToken: nil)
    }

    public func end(_ id: PiSession.ID) async throws {
        guard bridge.session(id: id) != nil else { return }
        let changes = bridge.changes()  // 先订阅再动手：下桥的那一刻不会漏
        try await bridge.end(id)
        let timeout = endTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await change in changes { if case .ended(let ended, _) = change, ended.id == id { return } }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PiHostError.notEnded
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    // MARK: 托管

    private func executable() throws -> URL {
        guard let claude = locator.candidates(AgentKind.claudeCode.command).first else { throw AgentRuntimeError.notInstalled(.claudeCode) }
        return claude
    }

    /// 起托管进程、握手、上桥；进程先退出或握手超时（这时让它退出）都抛错。
    private func launch(sessionID: String, arguments: [String], in directory: URL, launchToken: String?) async throws -> PiSession.ID {
        let claude = try executable()
        // App 的环境里没有用户 shell 的 PATH：把找 Claude Code 的那组目录加在前面（它的 Bash 工具在这个 PATH 下找命令），原有的留在后面
        let path = [locator.path, environment["PATH"]].compactMap { $0 }.joined(separator: ":")
        let session = try ClaudeHostedSession(
            executable: claude, arguments: arguments, sessionID: sessionID, directory: directory,
            environment: environment.merging(["PATH": path]) { $1 }, bridge: bridge, idleLimit: idleLimit)
        hosted[sessionID] = session
        Task { [weak self] in
            _ = await session.process.exited()
            if self?.hosted[sessionID] === session { self?.hosted[sessionID] = nil }
        }
        let cwd = URL(filePath: ClaudeCode.realPath(directory), directoryHint: .isDirectory)
        do {
            return try await session.connect(cwd: cwd, sessionFile: ClaudeCode.sessionFile(home: home, cwd: cwd, sessionID: sessionID), launchToken: launchToken).id
        } catch PiBridgeError.sessionEnded {
            throw ClaudeCodeError.exited(session.process.stderrTail)
        } catch PiBridgeError.ackTimeout {
            session.close()
            throw AgentRuntimeError.launchTimedOut(.claudeCode)
        }
    }

    // MARK: 终端会话

    /// 一次钩子调用：托管进程自己的直接放行（按进程认：环境变量会被从 CuePad 托管的会话里开的终端继承）；其余交给它所在的终端会话（第一次见到就上桥）。
    private func received(_ call: AgentHookCall) {
        let envelope = call.envelope
        guard !hosted.values.contains(where: { $0.process.pid == envelope.pid }), let input = ClaudeJSON.parse(envelope.input),
              let event = input["hook_event_name"]?.string, let sessionID = input["session_id"]?.string else { return call.finish() }
        let id = PiSession.claudeID(sessionID: sessionID, pid: envelope.pid)
        if event == "SessionEnd" {
            settle(id, reason: input["reason"]?.string)
            return call.finish()
        }
        let terminal = terminals[id] ?? appear(id: id, sessionID: sessionID, input: input, envelope: envelope)
        refresh(terminal, from: envelope)
        if event == "SessionStart" { hosted[sessionID]?.yield() }
        terminal.handle(event, input, call: call)
    }

    private func appear(id: PiSession.ID, sessionID: String, input: ClaudeJSON, envelope: AgentHookEnvelope) -> ClaudeTerminalSession {
        // 同一进程换了会话（/clear、/resume）却没收到 SessionEnd：旧的下桥
        for (other, terminal) in terminals where terminal.pid == envelope.pid && other != id { settle(other, reason: nil) }
        let cwd = URL(filePath: input["cwd"]?.string ?? "/", directoryHint: .isDirectory)
        let file = input["transcript_path"]?.string.map { URL(filePath: $0) } ?? ClaudeCode.sessionFile(home: home, cwd: cwd, sessionID: sessionID)
        var session = PiSession(
            id: id, sessionID: sessionID, agent: .claudeCode, sessionFile: file, pid: envelope.pid, cwd: cwd,
            terminal: PiTerminal(tty: envelope.tty, environment: envelope.environment), extensionVersion: 0, state: .settled, stateSince: .now)
        session.model = input["model"]?.string.map { ClaudeCode.model($0) }
        if let summary = ClaudeHistory.summary(of: file) {
            session.name = summary.name
            session.firstMessage = summary.firstMessage
        }
        return attach(session, inbox: envelope.environment["CLAUDE_CODE_MESSAGING_SOCKET"])
    }

    /// 启动时从会话列表补上的会话没有终端的环境变量：钩子带来时换上（同一 id 再上桥只换快照）。
    private func refresh(_ terminal: ClaudeTerminalSession, from envelope: AgentHookEnvelope) {
        if let inbox = envelope.environment["CLAUDE_CODE_MESSAGING_SOCKET"] { terminal.inbox = inbox }
        let fresh = PiTerminal(tty: envelope.tty, environment: envelope.environment)
        guard let current = bridge.session(id: terminal.id), current.terminal != fresh else { return }
        bridge.attach(current.with(terminal: fresh), via: terminal)
    }

    private func attach(_ session: PiSession, inbox: String?) -> ClaudeTerminalSession {
        let terminal = ClaudeTerminalSession(id: session.id, pid: session.pid, bridge: bridge, inbox: inbox)
        terminals[session.id] = terminal
        let pid = session.pid
        if exitWatchers[pid] == nil {
            exitWatchers[pid] = ProcessExitWatcher(pid: pid) { [weak self] in
                Task { @MainActor in self?.processExited(pid) }
            }
        }
        bridge.attach(session, via: terminal)
        return terminal
    }

    /// 会话结束（`SessionEnd`：退出、/clear、/resume 换走）：下桥。进程可能还在（换了会话），退出监视留着。
    private func settle(_ id: PiSession.ID, reason: String?) {
        guard let terminal = terminals.removeValue(forKey: id) else { return }
        terminal.close()
        let ended: PiSessionEndReason = switch reason {
        case nil: .disconnected
        case "clear": .closed(reason: "new")
        case "resume": .closed(reason: "resume")
        default: .closed(reason: "quit")
        }
        bridge.detach(id, reason: ended)
    }

    private func processExited(_ pid: Int32) {
        exitWatchers.removeValue(forKey: pid)?.cancel()
        for (id, terminal) in terminals where terminal.pid == pid { settle(id, reason: nil) }
    }

    // MARK: 已在跑的会话

    /// `claude agents --json` 列出的一个在跑的会话。
    private struct Running: Decodable {
        var pid: Int32
        var sessionID: String
        var cwd: String
        var status: String?
        enum CodingKeys: String, CodingKey {
            case pid, cwd, status
            case sessionID = "sessionId"
        }
    }

    private func running() async throws -> [Running] {
        guard let result = await runCapturing(try executable(), ["agents", "--json"], environment: environment, timeout: .seconds(15)),
              result.status == 0 else {
            throw ClaudeCodeError.listingFailed
        }
        return try JSONDecoder().decode([Running].self, from: Data(result.output.utf8))
    }

    /// CuePad 启动前就在跑的会话：补上桥。之后的变化靠钩子；钩子先到的已经上桥，不重复。
    private func discover() async {
        let list: [Running]
        do {
            list = try await running()
        } catch AgentRuntimeError.notInstalled {
            return
        } catch {
            return Self.log.notice("没能补上已在跑的 Claude Code 会话：\(String(describing: error))")
        }
        let ours = Set(hosted.values.map(\.process.pid))
        for entry in list where !ours.contains(entry.pid) && kill(entry.pid, 0) == 0 {
            let id = PiSession.claudeID(sessionID: entry.sessionID, pid: entry.pid)
            guard terminals[id] == nil else { continue }
            let cwd = URL(filePath: entry.cwd, directoryHint: .isDirectory)
            let file = ClaudeCode.sessionFile(home: home, cwd: cwd, sessionID: entry.sessionID)
            let state: PiWorkState = switch entry.status {
            case "busy": .thinking
            case "waiting": .waitingForUser
            default: .settled
            }
            var session = PiSession(
                id: id, sessionID: entry.sessionID, agent: .claudeCode, sessionFile: file, pid: entry.pid, cwd: cwd,
                terminal: PiTerminal(tty: Self.controllingTerminal(of: entry.pid)), extensionVersion: 0, state: state, stateSince: .now)
            if state != .settled { session.busySince = .now }
            if let summary = ClaudeHistory.summary(of: file) {
                session.name = summary.name
                session.firstMessage = summary.firstMessage
            }
            _ = attach(session, inbox: inbox(of: entry.pid))
        }
    }

    /// 会话的收件箱：Claude Code 的会话登记文件（`<配置目录>/sessions/<pid>.json`）里记着；`claude agents --json` 不给。
    private func inbox(of pid: Int32) -> String? {
        let file = home.appending(path: "sessions/\(pid).json")
        return (try? Data(contentsOf: file)).flatMap(ClaudeJSON.parse)?["messagingSocketPath"]?.string
    }

    /// 进程的控制终端名（如 `ttys012`）；没有终端为 nil。
    private static func controllingTerminal(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.e_tdev != UInt32(bitPattern: -1),
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        let tty = String(cString: name)
        return tty == "??" ? nil : tty
    }
}

public enum ClaudeCodeError: Error, Equatable, LocalizedError {
    /// 后台启动的 Claude Code 没握上手就退出了（附它的标准错误）
    case exited(String)
    /// `claude agents --json` 没有正常给出在跑的会话
    case listingFailed

    public var errorDescription: String? {
        switch self {
        case .exited(let stderr): stderr.isEmpty ? "在后台启动的 Claude Code 没连上就退出了" : "在后台启动的 Claude Code 退出了：\(stderr)"
        case .listingFailed: "没能问到 Claude Code 此刻在跑哪些会话"
        }
    }
}
#endif
