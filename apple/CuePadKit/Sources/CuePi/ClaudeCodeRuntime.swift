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
///   只接归 CuePad 管的（`follow` 给的范围，没接入时只有托管过的会话）：钩子与补上都按它，出了范围的下桥。
///   会话名与首条消息随钩子来（`session_title`、`UserPromptSubmit`）；重新上桥（托管接着、CuePad 重开后补上、钩子先到）时先取会话索引里记下的
///   （`remembered`，不在这里读会话文件），钩子带来新的再换。
/// - 托管会话：开新会话（`--session-id`）与接着已结束的会话（`--resume`，带上 CuePad 记下的这个会话最后的模型）；接着之前先确认它没开在别处（终端里开着时两边会各写各的）。
///   让出与空闲退出由桥决定（`PiBridge` 的托管会话一节）。
@MainActor
public final class ClaudeCodeRuntime: AgentRuntime {
    private static let log = Logger(subsystem: AppIdentity.id, category: "claude")
    private let bridge: PiBridge
    private let paths: AgentPaths
    private let hooks: AgentHookServer
    /// 这家的可执行文件（检测时挑中的那个，`AgentStatus.executable`）；没有为 nil
    private let claude: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    private let gate: PresenceGate
    private let store: CueStore
    private var terminals: [PiSession.ID: ClaudeTerminalSession] = [:]
    /// 每个终端进程一个退出监视；进程里此刻的会话见 `terminals`
    private var exitWatchers: [Int32: ProcessExitWatcher] = [:]
    private var hosted: [String: ClaudeHostedSession] = [:]  // 会话 id → 托管进程
    /// 终端会话哪些接上桥（`follow`）；给之前一个都不接
    private var scope = PiHistoryScope.sessions([])
    /// 量列表请求时限的钟
    private let timing: Timing

    public init(
        bridge: PiBridge, paths: AgentPaths, hooks: AgentHookServer, store: CueStore, claude: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, presence: any UserPresence = SystemPresence(),
        timing: Timing = .system
    ) {
        self.timing = timing
        self.claude = claude
        self.bridge = bridge
        self.paths = paths
        self.hooks = hooks
        self.locate = locate
        self.store = store
        gate = PresenceGate(presence: presence)
    }

    /// 索引器读会话文件存下的检查点；没索引过为 nil。
    private func checkpoint(of sessionID: String) async -> PiHistoryCheckpoint? {
        guard let data = try? await store.piCheckpoint(of: sessionID) else { return nil }
        return try? JSONDecoder().decode(PiHistoryCheckpoint.self, from: data)
    }

    /// 会话索引里记下的会话名与首条消息；没索引过为 nil。
    private func remembered(_ sessionID: String) async -> (name: String?, firstMessage: String?)? {
        await checkpoint(of: sessionID).map { ($0.name, $0.firstMessage) }
    }

    /// 上桥后补上索引里记下的名字与首条消息：首条消息以索引为准（钩子先到时记下的可能是重新接上后说的第一句），
    /// 名字钩子已带来的更新、不动。
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
    }

    public func follow(_ scope: PiHistoryScope) {
        self.scope = scope
        for id in terminals.keys where !scope.covers(sessionID: bridge.session(id: id)?.sessionID ?? "") { settle(id, reason: nil) }
        if scope != .sessions([]) { Task { await discover() } }
    }

    /// 托管的进程关了输入还不走就 SIGTERM、再不走 SIGKILL（`ChildProcess.stop`）；终端会话挂着的钩子放掉。
    /// 托管的进程靠管道连着 App，`stop()` 收掉它们。
    public var hostedSessionsOutliveApp: Bool { false }

    public func stop() -> @concurrent @Sendable () async -> Void {
        for terminal in terminals.values { terminal.close() }
        for watcher in exitWatchers.values { watcher.cancel() }
        exitWatchers = [:]
        let processes = hosted.values.compactMap(\.stream?.process)
        return { for process in processes { await process.stop() } }
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        let sessionID = UUID().uuidString.lowercased()
        let id = try await launch(sessionID: sessionID, arguments: ["--session-id", sessionID], in: directory, launchToken: launchToken)
        return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
    }

    /// 终端里的会话被停下时不跑钩子，会话文件里的中断标记是这一轮结束的唯一消息（`ClaudeTerminalSession.stopped`）；
    /// 托管的会话有 `result`，用不着。
    public func read(_ update: PiHistoryUpdate) {
        guard let stoppedAt = update.checkpoint.stoppedAt else { return }
        for (id, terminal) in terminals where bridge.session(id: id)?.sessionID == update.sessionID { terminal.stopped(at: stoppedAt) }
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        if let running = hosted[session.id], let id = running.id { return id }
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
            in: directory, launchToken: nil, known: await remembered(session.id))
    }

    // MARK: 托管

    /// `claude` 与给它的环境：`paths` 里指定的（隔离的配置目录等）盖在本进程的环境上。不自己补 `CLAUDE_CONFIG_DIR`：
    /// 设了它 Claude Code 就到那个目录里找 `.claude.json`，与没设时的 `~/.claude.json` 不是一份。
    private func executable() async throws -> (url: URL, environment: [String: String]) {
        guard let claude = await claude() else { throw AgentRuntimeError.notInstalled(.claudeCode) }
        let locator = await locate()
        return (claude, locator.environment(launching: claude, overrides: paths.environment))
    }

    /// 起托管进程、握手、上桥；进程先退出或握手超时（这时让它退出）都抛错。
    private func launch(
        sessionID: String, arguments: [String], model: PiModelKey? = nil, in directory: URL, launchToken: String?,
        known: (name: String?, firstMessage: String?)? = nil
    ) async throws -> PiSession.ID {
        let claude = try await executable()
        let session = ClaudeHostedSession(bridge: bridge)
        let process = try await session.host(
            executable: claude.url, arguments: arguments, directory: directory,
            environment: claude.environment.merging([HostMark.variable: sessionID]) { $1 })
        hosted[sessionID] = session
        Task { [weak self] in
            _ = await process.exited()
            if self?.hosted[sessionID] === session { self?.hosted[sessionID] = nil }
        }
        let cwd = URL(filePath: ClaudeCode.realPath(directory), directoryHint: .isDirectory)
        do {
            return try await session.connect(
                sessionID: sessionID, cwd: cwd, sessionFile: ClaudeCode.sessionFile(home: home, cwd: cwd, sessionID: sessionID), model: model, launchToken: launchToken,
                known: known).id
        } catch PiBridgeError.sessionEnded {
            throw ClaudeCodeError.exited(await process.exited())
        } catch PiBridgeError.ackTimeout {
            await process.stop()
            throw AgentRuntimeError.launchTimedOut(.claudeCode)
        }
    }

    // MARK: 终端会话

    /// 一次钩子调用：托管会话自己的直接放行（状态来自 stream-json）——按环境里的 `HostMark`（值是会话 id）认，还要对上会话
    /// （从托管会话里开的终端继承了标记）；其余交给它所在的终端会话（第一次见到就上桥）。
    private func received(_ call: AgentHookCall) {
        let envelope = call.envelope
        guard let input = JSONValue.parse(envelope.input), let event = input["hook_event_name"]?.string,
              let sessionID = input["session_id"]?.string,
              envelope.environment[HostMark.variable] != sessionID || hosted[sessionID] == nil else { return call.finish() }
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
        var session = PiSession(
            id: id, sessionID: sessionID, agent: .claudeCode, sessionFile: file, pid: envelope.pid, cwd: cwd,
            terminal: PiTerminal(tty: envelope.tty, environment: envelope.environment), state: .settled, stateSince: .now)
        session.model = input["model"]?.string.map { ClaudeCode.model($0) }
        let terminal = attach(session, inbox: envelope.environment["CLAUDE_CODE_MESSAGING_SOCKET"], runningSince: nil, waiting: false)
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

    private func attach(_ session: PiSession, inbox: String?, runningSince: Date?, waiting: Bool) -> ClaudeTerminalSession {
        let terminal = ClaudeTerminalSession(
            id: session.id, pid: session.pid, bridge: bridge, gate: gate, inbox: inbox, runningSince: runningSince, waiting: waiting)
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

    /// CuePad 启动前就在跑的会话：补上桥。之后的变化靠钩子；钩子先到的已经上桥，不重复。
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
        for entry in list where hosted[entry.sessionID] == nil && scope.covers(sessionID: entry.sessionID) && kill(entry.pid, 0) == 0 {
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
                pid: entry.pid, cwd: cwd, terminal: PiTerminal(tty: Self.controllingTerminal(of: entry.pid)),
                state: .settled, stateSince: .now)
            _ = attach(session, inbox: inbox(of: entry.pid), runningSince: running, waiting: waiting)
            recall(id, sessionID: entry.sessionID)
        }
    }

    /// 会话文件里最后一轮的开始（`PiHistoryCheckpoint.lastTurnStart`）：从索引器存下的检查点接着读（会话文件可能有几百 MB），
    /// 没有或已失效从头读；文件还没落盘或读不了为 nil。
    @concurrent private static func lastTurnStart(in file: URL, from checkpoint: PiHistoryCheckpoint?, files: AttachmentFiles) async -> Date? {
        try? PiHistory.index(file: file, agent: .claudeCode, from: checkpoint, transcript: false, files: files).checkpoint.lastTurnStart
    }

    /// 会话的收件箱：Claude Code 的会话登记文件（`<配置目录>/sessions/<pid>.json`，官方没有写）里记着；`claude agents --json` 不给。
    private func inbox(of pid: Int32) -> String? {
        let file = home.appending(path: "sessions/\(pid).json")
        return (try? Data(contentsOf: file)).flatMap(JSONValue.parse)?["messagingSocketPath"]?.string
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

public enum ClaudeCodeError: Error, Equatable, ShownError {
    /// 后台启动的 Claude Code 没握上手就退出了（附它的退出原因；`stop()` 让它退的没有）
    case exited(ShownText?)
    /// `claude agents --json` 没有正常给出在跑的会话
    case listingFailed

    public var shown: String.LocalizationValue {
        switch self {
        case .exited(let reason): reason.map { "在后台启动的 Claude Code 退出了：\($0.embedded)" } ?? "在后台启动的 Claude Code 没连上就退出了"
        case .listingFailed: "没能问到 Claude Code 此刻在跑哪些会话"
        }
    }
}
#endif
