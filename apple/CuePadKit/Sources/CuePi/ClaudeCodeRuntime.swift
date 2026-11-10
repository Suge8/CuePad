#if os(macOS)
import CueStore
import Darwin
import Foundation
import OSLog

/// 重新上桥（托管接着、CuePad 重开后补上、钩子先到）时先取会话索引里记下的名字与首条消息（`remembered`，不在这里读会话文件），钩子带来新的再换。
/// 托管会话的让出与空闲退出由桥决定（`PiBridge` 的托管会话一节）。
@MainActor
public final class ClaudeCodeRuntime: AgentRuntime {
    private static let log = Logger(subsystem: AppIdentity.id, category: "claude")
    private let bridge: PiBridge
    private let paths: AgentPaths
    private let hooks: AgentHookServer
    private let claude: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    private let gate: PresenceGate
    private let store: CueStore
    private var terminals: [PiSession.ID: ClaudeTerminalSession] = [:]
    private var exitWatchers: [Int32: ProcessExitWatcher] = [:]
    private let hosted: HostedProcesses
    private var scope = PiHistoryScope.sessions([])
    private let timing: Timing

    public init(
        bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer, store: CueStore, claude: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, presence: any UserPresence = SystemPresence(),
        timing: Timing = .system
    ) {
        self.timing = timing
        self.claude = claude
        self.bridge = bridge
        hosted = HostedProcesses(bridge: bridge, timing: timing)
        self.paths = paths
        self.hooks = hooks
        self.locate = locate
        self.store = store
        gate = PresenceGate(presence: presence)
    }

    private func checkpoint(of sessionID: String) async -> PiHistoryCheckpoint? {
        guard let data = try? await store.piCheckpoint(of: sessionID) else { return nil }
        return try? JSONDecoder().decode(PiHistoryCheckpoint.self, from: data)
    }

    private func remembered(_ sessionID: String) async -> (name: String?, firstMessage: String?)? {
        await checkpoint(of: sessionID).map { ($0.name, $0.firstMessage) }
    }

    /// 首条消息以索引为准（钩子先到时记下的可能是重新接上后说的第一句），名字钩子已带来的更新、不动。
    private func recall(_ id: PiSession.ID, sessionID: String) {
        Task { [weak self] in
            guard let known = await self?.remembered(sessionID) else { return }
            self?.bridge.update(id) { session in
                if session.name == nil { session.name = known.name }
                if let first = known.firstMessage { session.firstMessage = first }
            }
        }
    }

    private var home: URL { paths.home(of: .claudeCode) }

    public func start() throws {
        hooks.handle(.claudeCode) { [weak self] call in self?.received(call) }
        hosted.start()
    }

    public func follow(_ scope: PiHistoryScope) {
        self.scope = scope
        for id in terminals.keys where !scope.covers(sessionID: bridge.session(id: id)?.sessionID ?? "") { settle(id, reason: nil) }
        if scope != .sessions([]) { Task { await discover() } }
    }

    public func stop() -> @concurrent @Sendable () async -> Void {
        for terminal in terminals.values { terminal.close() }
        for watcher in exitWatchers.values { watcher.cancel() }
        exitWatchers = [:]
        return hosted.stop()
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        let sessionID = UUID().uuidString.lowercased()
        let id = try await launch(
            sessionID: sessionID, arguments: ["--session-id", sessionID], in: directory, launchToken: launchToken, admission: try hosted.admission())
        return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
    }

    /// 终端里的会话被停下、这句被钩子挡下时不跑钩子，会话文件里的那一行是这一轮结束的唯一消息（`ClaudeTerminalSession.stopped`、`promptEnded`）；
    /// 托管的会话有 `result`，用不着。
    public func read(_ update: PiHistoryUpdate) {
        let checkpoint = update.checkpoint
        for (id, terminal) in terminals where bridge.session(id: id)?.sessionID == update.sessionID {
            if let stoppedAt = checkpoint.stoppedAt { terminal.stopped(at: stoppedAt) }
            if let endedAt = checkpoint.promptEndedAt { terminal.promptEnded(at: endedAt) }
        }
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let live = bridge.sessions.first(where: { $0.agent == .claudeCode && $0.sessionID == session.id && $0.hosted }) { return live.id }
        return try await hosted.resume(session.id) { [self] admission in
            if bridge.sessions.contains(where: { $0.agent == .claudeCode && $0.sessionID == session.id && !$0.hosted }) {
                throw AgentRuntimeError.openElsewhere
            }
            // 还没触发过钩子的终端会话（钩子没装、或 CuePad 之后才启动）桥上没有，问 Claude Code 自己
            if try await running().contains(where: { $0.sessionID == session.id }) { throw AgentRuntimeError.openElsewhere }
            let directory = URL(filePath: session.cwd, directoryHint: .isDirectory)
            // Claude Code 接着会话时用配置里的模型，不记得这个会话里换过的：带上 CuePad 记下的
            let model = try? await store.lastModel(ofSession: session.id)
            return try await launch(
                sessionID: session.id, arguments: ["--resume", session.id] + (model.map { ["--model", $0.id] } ?? []), model: model,
                in: directory, launchToken: nil, known: await remembered(session.id), admission: admission)
        }
    }

    /// 不自己补 `CLAUDE_CONFIG_DIR`：设了它 Claude Code 就到那个目录里找 `.claude.json`，与没设时的 `~/.claude.json` 不是一份。
    private func executable() async throws -> (url: URL, environment: [String: String]) {
        guard let claude = await claude() else { throw AgentRuntimeError.notInstalled(.claudeCode) }
        let locator = await locate()
        return (claude, locator.environment(launching: claude, overrides: paths.environment))
    }

    /// 没连上就抛错：进程先退出、握手超时，或调用方取消（投送到了截止时刻）。没连上的都收掉自己起的进程（只收它：
    /// 按会话收会收到别人的），不留一个不在桥上的进程占着这个会话（之后接着它时被当成在别处开着，或再起一个同写会话文件）。
    private func launch(
        sessionID: String, arguments: [String], model: PiModelKey? = nil, in directory: URL, launchToken: String?,
        known: (name: String?, firstMessage: String?)? = nil, admission: HostedProcesses.Admission
    ) async throws -> PiSession.ID {
        let claude = try await executable()
        let session = ClaudeHostedSession(bridge: bridge, processes: hosted, timing: timing)
        // 交给会话的附件在工作目录外（`AttachmentFiles.directory`）：读它不用再问
        let process = try await session.host(
            executable: claude.url, arguments: arguments + ["--add-dir", store.files.directory.path(percentEncoded: false)], directory: directory,
            environment: claude.environment.merging([HostMark.variable: sessionID]) { $1 })
        try await hosted.admit(process, for: sessionID, admission)
        let cwd = URL(filePath: ClaudeCode.realPath(directory), directoryHint: .isDirectory)
        do {
            return try await session.connect(
                sessionID: sessionID, cwd: cwd, sessionFile: ClaudeCode.sessionFile(home: home, cwd: cwd, sessionID: sessionID), model: model, launchToken: launchToken,
                known: known).id
        } catch PiBridgeError.sessionEnded {
            let reason = await process.exited()
            throw ClaudeCodeError.exited(reason)
        } catch {
            await process.stop()
            if error as? PiBridgeError == .ackTimeout { throw AgentRuntimeError.launchTimedOut(.claudeCode) }
            throw error
        }
    }

    /// 原样放行、不登记的两种：
    /// - 不是 Claude Code 发的：Claude Code 按每次钩子的输入设环境里的 `CLAUDE_CODE_SESSION_ID`，与输入里的 `session_id` 相同；
    ///   照读 `~/.claude/settings.json` 跑这些钩子的别家（Grok Build、Cursor、OpenCode 的兼容插件）没有它，或是从 Claude Code
    ///   里起时继承来的别的会话；
    /// - 托管会话自己的（状态来自 stream-json）：环境里的 `HostMark`（值是会话 id）对上一个托管会话（从托管会话里开的终端继承了标记，会话不同）。
    private func received(_ call: AgentHookCall) {
        let envelope = call.envelope
        guard let input = JSONValue.parse(envelope.input), let event = input["hook_event_name"]?.string,
              let sessionID = input["session_id"]?.string, envelope.environment["CLAUDE_CODE_SESSION_ID"] == sessionID,
              envelope.environment[HostMark.variable] != sessionID || !hosted.sessionIDs.contains(sessionID) else { return call.finish() }
        let id = PiSession.claudeID(sessionID: sessionID, pid: envelope.pid)
        if event == "SessionEnd" {
            settle(id, reason: input["reason"]?.string)
            return call.finish()
        }
        guard terminals[id] != nil || scope.covers(sessionID: sessionID) else { return call.finish() }
        let terminal = terminals[id] ?? appear(id: id, sessionID: sessionID, input: input, envelope: envelope)
        refresh(terminal, from: envelope)
        terminal.handle(event, input, call: call)
    }

    private func appear(id: PiSession.ID, sessionID: String, input: JSONValue, envelope: AgentHookEnvelope) -> ClaudeTerminalSession {
        // 同一进程换了会话（/clear、/resume）却没收到 SessionEnd：旧的下桥
        for (other, terminal) in terminals where terminal.pid == envelope.pid && other != id { settle(other, reason: nil) }
        let cwd = URL(filePath: input["cwd"]?.string ?? "/", directoryHint: .isDirectory)
        let file = input["transcript_path"]?.string.map { URL(filePath: $0) } ?? ClaudeCode.sessionFile(home: home, cwd: cwd, sessionID: sessionID)
        let session = PiSession(
            id: id, sessionID: sessionID, agent: .claudeCode, sessionFile: file, pid: envelope.pid, cwd: cwd,
            terminal: PiTerminal(tty: envelope.tty, environment: envelope.environment), state: .settled, stateSince: .now)
        let terminal = attach(
            session, inbox: envelope.environment["CLAUDE_CODE_MESSAGING_SOCKET"], registry: registry(of: envelope.pid, in: home(of: envelope)),
            runningSince: nil, waiting: false)
        recall(id, sessionID: sessionID)
        return terminal
    }

    /// 启动时从会话列表补上的会话没有终端的环境变量：钩子带来时换上。
    private func refresh(_ terminal: ClaudeTerminalSession, from envelope: AgentHookEnvelope) {
        if let inbox = envelope.environment["CLAUDE_CODE_MESSAGING_SOCKET"] { terminal.inbox = inbox }
        if let token = envelope.environment["CLAUDE_CODE_MESSAGING_TOKEN"] { terminal.inboxToken = token }
        let fresh = PiTerminal(tty: envelope.tty, environment: envelope.environment)
        bridge.update(terminal.id) { $0.terminal = fresh }
    }

    /// - Parameter registry: 会话登记文件，在会话自己的配置目录里（钩子来的见 `home(of:)`，列表补上的就是 `home`）
    private func attach(_ session: PiSession, inbox: String?, registry: URL, runningSince: Date?, waiting: Bool) -> ClaudeTerminalSession {
        let terminal = ClaudeTerminalSession(
            id: session.id, pid: session.pid, bridge: bridge, gate: gate, inbox: inbox, registry: registry,
            timing: timing, runningSince: runningSince, waiting: waiting)
        terminals[session.id] = terminal
        let pid = session.pid
        if exitWatchers[pid] == nil {
            exitWatchers[pid] = ProcessExitWatcher(pid: pid) { [weak self] in self?.processExited(pid) }
        }
        var session = session
        terminal.publish(&session)
        bridge.attach(session, via: terminal)
        return terminal
    }

    /// 进程可能还在（换了会话），退出监视留着。
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
        let claude = try await executable()
        guard let result = await ChildProcess.run(claude.url, ["agents", "--json"], environment: claude.environment, timeout: AgentTimeouts.list, timing: timing),
              result.status == 0 else {
            throw ClaudeCodeError.listingFailed
        }
        return try JSONDecoder().decode([Running].self, from: Data(result.output.utf8))
    }

    private func discover() async {
        let list: [Running]
        let listed = Date.now  // 会话文件里读不到一轮时的开始：列表里在跑的那一轮此刻之后才收尾
        do {
            list = try await running()
        } catch AgentRuntimeError.notInstalled {
            return
        } catch {
            return Self.log.notice("没能补上已在跑的 Claude Code 会话：\(String(describing: error))")
        }
        for entry in list where !hosted.sessionIDs.contains(entry.sessionID) && scope.covers(sessionID: entry.sessionID) && kill(entry.pid, 0) == 0 {
            let id = PiSession.claudeID(sessionID: entry.sessionID, pid: entry.pid)
            guard terminals[id] == nil else { continue }
            let cwd = URL(filePath: entry.cwd, directoryHint: .isDirectory)
            let file = ClaudeCode.sessionFile(home: home, cwd: cwd, sessionID: entry.sessionID)
            let waiting = entry.status == "waiting"
            let running = waiting || entry.status == "busy"
                ? await Self.lastTurnStart(in: file, from: checkpoint(of: entry.sessionID), files: store.files) ?? listed : nil
            guard terminals[id] == nil, scope.covers(sessionID: entry.sessionID) else { continue }  // 读文件时钩子先到、已上桥，或范围换了
            let session = PiSession(
                id: id, sessionID: entry.sessionID, agent: .claudeCode, sessionFile: file,
                pid: entry.pid, cwd: cwd, terminal: PiTerminal(tty: PiTerminal.controllingTerminal(of: entry.pid)),
                state: .settled, stateSince: .now)
            _ = attach(session, inbox: inbox(of: entry.pid), registry: registry(of: entry.pid, in: home), runningSince: running, waiting: waiting)
            recall(id, sessionID: entry.sessionID)
        }
    }

    /// 从索引器存下的检查点接着读（会话文件可能有几百 MB），没有或已失效从头读；文件还没落盘或读不了为 nil。
    @concurrent private static func lastTurnStart(in file: URL, from checkpoint: PiHistoryCheckpoint?, files: AttachmentFiles) async -> Date? {
        try? PiHistory.index(file: file, agent: .claudeCode, from: checkpoint, transcript: false, files: files).checkpoint.lastTurnStart
    }

    /// 会话的收件箱：Claude Code 的会话登记文件（`<配置目录>/sessions/<pid>.json`，官方没有写）里记着；`claude agents --json` 不给。
    private func inbox(of pid: Int32) -> String? {
        (try? Data(contentsOf: registry(of: pid, in: home))).flatMap(JSONValue.parse)?["messagingSocketPath"]?.string
    }

    private func registry(of pid: Int32, in home: URL) -> URL { home.appending(path: "sessions/\(pid).json") }

    /// 终端会话自己的配置目录：用户可以给它另设 `CLAUDE_CONFIG_DIR`（钩子环境带着），没设就是默认的那个，不一定是 CuePad 读的 `home`
    private func home(of envelope: AgentHookEnvelope) -> URL {
        let variable = AgentKind.claudeCode.facts.homeVariable
        var environment = paths.environment
        environment[variable] = envelope.environment[variable]
        return AgentPaths(pi: paths.pi, environment: environment).home(of: .claudeCode)
    }
}

public enum ClaudeCodeError: Error, Equatable, ShownError {
    /// 附它的退出原因；`stop()` 让它退的没有
    case exited(ShownText?)
    case listingFailed

    public var shown: String.LocalizationValue {
        switch self {
        case .exited(let reason): reason.map { "在后台启动的 Claude Code 退出了：\($0.embedded)" } ?? "在后台启动的 Claude Code 没连上就退出了"
        case .listingFailed: "没能问到 Claude Code 此刻在跑哪些会话"
        }
    }
}
#endif
