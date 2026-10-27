#if os(macOS)
import CueStore
import Darwin
import Foundation

/// Grok Build（xAI）的接入，经 ACP：驱动是通用的 `ACPSession`，Grok 自己的扩展在 `GrokDialect`。
/// - 托管会话：CuePad 起 `grok agent --no-leader stdio`，用用户的配置目录（会话落在 `<GROK_HOME>/sessions`，`grok --resume` 里也有）；
///   开新会话是 `session/new`，接着已结束的是 `session/load`。歇满 `PiBridge.hostedIdle` 由桥请它退出。发出的话带着投送请求 id
///   （`GrokDialect.promptMeta`），会话记录里认得回（`GrokHistory`）。
/// - 终端里的会话（TUI）只读跟读：开着的登记在 `<GROK_HOME>/active_sessions.json`（会话 id、pid、工作目录；正常退出时注销，
///   崩溃留下的由下一个登记的清掉），盯着它所在的目录，范围里（`follow`）、进程还在的上桥，注销或进程退出就下桥。
///   在做什么从它的会话记录推出（历史索引增量跟读，`read`）：你说了一句到这一轮结束是在跑；等你确认、出错的原话不进会话记录，看不到。
///   CuePad 碰不到它的输入，说话、停止、作答、结束都只能在终端里（能力表里终端的 Grok 什么都没有）。
///   用户开了 leader（`grok --leader`）时终端界面是 leader 的客户端，连上 leader 能完全接管：不做——leader 的协议没有文档，
///   CuePad 也不常连用户的 leader 进程。不装 Grok 自己的钩子（`~/.grok/hooks`）：会话记录已给出一轮的起止与工具，钩子多给的只有等你确认。
///   Grok 也跑 Claude Code 格式的钩子，CuePad 写给 Claude Code 的钩子在终端的 Grok 里也会被调起，钩子入口只认 Claude Code 发的。
@MainActor
public final class GrokRuntime: AgentRuntime {
    private let bridge: PiBridge
    private let paths: AgentPaths
    private let files: AttachmentFiles
    private let host: ACPHost
    /// 在桥上的终端会话
    private var terminals: [PiSession.ID: Terminal] = [:]
    private var watcher: DirectoryWatcher?
    /// 终端会话哪些接上桥（`follow`）；给之前一个都不接
    private var scope = PiHistoryScope.sessions([])
    private var stopped = true

    private final class Terminal {
        var facts = SessionFacts()
        var exit: ProcessExitWatcher?
    }

    public init(
        bridge: PiBridge, paths: AgentPaths, files: AttachmentFiles, grok: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, timing: Timing = .system
    ) {
        self.bridge = bridge
        self.paths = paths
        self.files = files
        let home = paths.home(of: .grok)
        host = ACPHost(.grok, bridge: bridge, timing: timing, launching: { _ in
            guard let grok = await grok() else { throw AgentRuntimeError.notInstalled(.grok) }
            let environment = await locate().environment(launching: grok, overrides: paths.environment.merging([Self.facts.homeVariable: home.path]) { $1 })
            return ACPHost.Launching(executable: grok, environment: environment, dialect: GrokDialect())
        }, sessionFile: { cwd, id in Self.sessionFile(in: home, cwd: cwd.path, id: id) })
    }

    private var home: URL { paths.home(of: .grok) }

    // MARK: AgentRuntime

    public func start() throws {
        stopped = false
    }

    public func follow(_ scope: PiHistoryScope) {
        self.scope = scope
        refresh()
    }

    /// 托管的会话在 App 起的进程里，`stop()` 收掉它们。
    public var hostedSessionsOutliveApp: Bool { false }

    public func stop() -> @concurrent @Sendable () async -> Void {
        stopped = true
        watcher = nil
        for id in terminals.keys { detach(id) }
        return host.stop()
    }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        let id = try await host.open(in: directory, launchToken: launchToken)
        return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID { try await host.resume(session) }

    public func read(_ update: PiHistoryUpdate) {
        guard let (id, terminal) = terminals.first(where: { bridge.session(id: $0.key)?.sessionID == update.sessionID }) else { return }
        follow(terminal, update.checkpoint)
        bridge.update(id) { terminal.facts.publish(to: &$0) }
    }

    // MARK: 终端

    /// 对一遍开着的终端会话：新登记的上桥，注销了的下桥。目录在之前还没有（后装的 Grok）时这时开始盯。
    private func refresh() {
        guard !stopped else { return }
        if watcher == nil { watcher = try? DirectoryWatcher(home) { [weak self] in self?.refresh() } }
        let hostedIDs = host.sessionIDs
        let open = Self.activeSessions(in: home).filter { scope.covers(sessionID: $0.sessionID) && !hostedIDs.contains($0.sessionID) && kill($0.pid, 0) == 0 }
        let ids = Set(open.map { "\($0.sessionID).\($0.pid)" })
        for id in terminals.keys where !ids.contains(id) { detach(id) }
        for entry in open where terminals["\(entry.sessionID).\(entry.pid)"] == nil { attach(entry) }
    }

    private func attach(_ entry: ActiveSession) {
        let id = "\(entry.sessionID).\(entry.pid)"
        let terminal = Terminal()
        terminals[id] = terminal
        terminal.exit = ProcessExitWatcher(pid: entry.pid) { [weak self] in self?.detach(id) }
        let file = Self.sessionFile(in: home, cwd: entry.cwd, id: entry.sessionID)
        var session = PiSession(
            id: id, sessionID: entry.sessionID, agent: .grok, sessionFile: file, pid: entry.pid,
            cwd: URL(filePath: entry.cwd, directoryHint: .isDirectory), terminal: PiTerminal(tty: PiTerminal.controllingTerminal(of: entry.pid)),
            state: .settled, stateSince: .now)
        // 接上时已在跑的：从会话记录读出这一轮的开始（之后的由历史索引跟读，`read`）
        if let checkpoint = try? PiHistory.index(file: file, agent: .grok, from: nil, transcript: false, files: files).checkpoint {
            follow(terminal, checkpoint)
        }
        terminal.facts.publish(to: &session)
        bridge.attach(session, via: self)
    }

    private func follow(_ terminal: Terminal, _ checkpoint: PiHistoryCheckpoint) {
        if let round = checkpoint.round {
            if !terminal.facts.running { terminal.facts.startTurn(at: round.startedAt ?? .now) }
        } else if terminal.facts.running {
            terminal.facts.endTurn()
        }
    }

    private func detach(_ id: PiSession.ID) {
        guard let terminal = terminals.removeValue(forKey: id) else { return }
        terminal.exit?.cancel()
        bridge.detach(id, reason: .closed(reason: "quit"))
    }

    /// `active_sessions.json` 里的一项（Grok 的 `ActiveSession`）
    struct ActiveSession: Decodable {
        var sessionID: String
        var pid: Int32
        var cwd: String

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case pid, cwd
        }
    }

    static func activeSessions(in home: URL) -> [ActiveSession] {
        (try? Data(contentsOf: home.appending(path: "active_sessions.json"))).flatMap { try? JSONDecoder().decode([ActiveSession].self, from: $0) } ?? []
    }

    /// 会话记录：`<GROK_HOME>/sessions/<工作目录>/<会话 id>/updates.jsonl`，工作目录照 URL 的写法编码（只留字母、数字与 `-._~`，同 Grok 用的 urlencoding）。
    static func sessionFile(in home: URL, cwd: String, id: String) -> URL {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return home.appending(path: "sessions", directoryHint: .isDirectory)
            .appending(path: cwd.addingPercentEncoding(withAllowedCharacters: unreserved) ?? cwd, directoryHint: .isDirectory)
            .appending(path: id, directoryHint: .isDirectory).appending(path: facts.sessionFiles?.fileName ?? "updates.jsonl")
    }
}

/// 终端里的会话只读：桥按能力表先拒掉，到不了这里。
extension GrokRuntime: SessionLink {}
#endif
