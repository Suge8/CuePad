#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 真 Claude Code 的端到端测试台：配置目录、HOME、XDG 目录、CuePad 的连接目录与资料库全部指到临时目录，绝不碰 ~/.claude 与真实资料库。
/// 模型走本机 Claude Code 自己的登录（`ClaudeLogin`，模型 `haiku` 省额度），录制与直连时现取。
/// 终端会话跑在私有 tmux 服务器里（`tmux -L`），结束时按确切 pid 停掉 Claude Code 与那个 tmux 服务器。
let claudeURL = ExecutableLocator.standard.candidates("claude").first
let tmuxURL = ExecutableLocator.standard.candidates("tmux").first
/// 测试用的模型与换模型时换到的另一个
let claudeTestModel = "haiku", claudeOtherModel = "sonnet"

/// 256×256 纯红 PNG（32×32 的常被模型认成别的颜色）
let redPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAIAAADTED8xAAAB+0lEQVR42u3TQQkAAAjAwPUvrX8reHAJBmsK3pIAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgAJMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAyAASTAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADADHAllMDvLkz2XNAAAAAElFTkSuQmCC")!

@MainActor
final class ClaudeTestbed {
    let root: URL
    let config: URL
    /// 工作目录（真实路径：Claude Code 记的就是它）
    let work: URL
    let sockets: URL
    let environment: [String: String]
    let paths: AgentPaths
    let bridge: PiBridge
    let hooks: AgentHookServer
    let runtime: ClaudeCodeRuntime
    /// 人在不在这台 Mac 前：默认不在（提问交给 CuePad）
    let presence: TestPresence
    let files: AttachmentFiles
    private let store: CueStore
    /// 桥上从测试台起来以后的全部变化
    let log: ChangeLog
    private var terminals: [ClaudeTerminal] = []
    /// 终端会话的会话文件跟读（同 App：历史索引读到的交给接入，`AgentRuntime.read`）；开第一个终端时起
    private var reading: Task<Void, Never>?

    var integration: AgentIntegration {
        AgentIntegration(paths: paths, locate: { AgentTape.locator("claude") }, cuepad: PiProcess.cuepad)
    }

    /// - Parameter settings: 装钩子之前用户自己的 settings.json（nil 是没有这个文件）。
    /// - Parameter wrapper: CuePad 起的 `claude` 换成这段 shell 脚本的外壳，真 claude 在 `$REAL`（`passThrough`：托管进程是它的子进程，
    ///   钩子的父进程不是 CuePad 起的那个）。终端里开的仍是真 claude。
    init(installHooks: Bool = true, settings: String? = nil, idleLimit: Duration = .seconds(1800), wrapper: String? = nil) async throws {
        root = try makeTempDirectory()
        config = root.appending(path: "config")
        sockets = root.appending(path: "s")
        let workDirectory = root.appending(path: "work")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        work = URL(filePath: ClaudeCode.realPath(workDirectory), directoryHint: .isDirectory)
        for name in ["config", "home", "xdg-data", "xdg-state", "xdg-cache", "xdg-config", "library"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        // 跳过首次启动的引导与"信任这个目录"的询问
        let seed: JSONValue = ["hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true, "projects": .object([work.path: ["hasTrustDialogAccepted": true]])]
        try seed.data.write(to: config.appending(path: ".claude.json"))
        if let settings { try Data(settings.utf8).write(to: config.appending(path: "settings.json")) }
        AgentTape.current?.watch(config.appending(path: "projects"), work)
        environment = [
            "CLAUDE_CONFIG_DIR": config.path, "HOME": root.appending(path: "home").path,
            "XDG_DATA_HOME": root.appending(path: "xdg-data").path, "XDG_STATE_HOME": root.appending(path: "xdg-state").path,
            "XDG_CACHE_HOME": root.appending(path: "xdg-cache").path, "XDG_CONFIG_HOME": root.appending(path: "xdg-config").path,
            "CUEPAD_PI_SOCKET_DIR": sockets.path, "CUEPAD_LIBRARY_DIR": root.appending(path: "library").path,
            "CLAUDE_CODE_OAUTH_TOKEN": AgentTape.current?.mode == .replay ? "" : ClaudeLogin.token ?? "", "ANTHROPIC_API_KEY": "",
            // 不要自动记忆：叫它"记住"什么时它会先去翻记忆文件、要用 Bash，等你确认
            "ANTHROPIC_MODEL": claudeTestModel, "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
        ]
        paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
        store = try Fixture().store
        files = store.files
        bridge = PiBridge(socketDirectory: sockets, hostedIdle: idleLimit)
        log = ChangeLog(bridge)
        try bridge.start()
        hooks = AgentHookServer(path: paths.pi.hookSocket)
        try hooks.start()
        let presence = TestPresence()
        self.presence = presence
        var bin = AgentTape.executable("claude").deletingLastPathComponent()
        if let wrapper {
            let real = bin.appending(path: "claude")
            bin = root.appending(path: "wrapper", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let script = bin.appending(path: "claude")
            try "#!/bin/sh\nREAL='\(real.path)'\n\(wrapper)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        runtime = ClaudeCodeRuntime(
            bridge: bridge, paths: paths, hooks: hooks, store: store, claude: { [bin] in bin.appending(path: "claude") },
            locate: { [bin] in ExecutableLocator(searchDirectories: [bin]) },
            presence: presence)
        if installHooks { try await integration.install(.claudeCode) }
    }

    /// 搭好测试台跑 `body`，不论成败都停掉起的进程（临时目录随测试进程退出整体删除）。
    static func run(
        installHooks: Bool = true, settings: String? = nil, idleLimit: Duration = .seconds(1800), wrapper: String? = nil,
        _ body: (ClaudeTestbed) async throws -> Void
    ) async throws {
        let testbed = try await ClaudeTestbed(installHooks: installHooks, settings: settings, idleLimit: idleLimit, wrapper: wrapper)
        do {
            try await body(testbed)
        } catch {
            await testbed.stop()
            throw error
        }
        await testbed.stop()
    }

    /// 在私有 tmux 里开一个终端里的 Claude Code（权限模式默认 default：要用工具就问）。
    func terminal(_ arguments: [String] = [], mode: String = "default") async throws -> ClaudeTerminal {
        if reading == nil, let indexer = PiHistoryIndexer(agent: .claudeCode, paths: paths, files: files, start: { _ in nil }) {
            reading = Task { [runtime, bridge] in
                for await case .updated(let update) in indexer.events(following: bridge.sessionFiles, scope: .all) { runtime.read(update) }
            }
        }
        let terminal = try await ClaudeTerminal(testbed: self, arguments: ["--permission-mode", mode] + arguments)
        terminals.append(terminal)
        return terminal
    }

    /// 桥上这个进程里的会话
    func session(pid: Int32) -> PiSession? { bridge.sessions.first { $0.pid == pid && $0.agent == .claudeCode } }

    func waitForSession(pid: Int32) async throws -> PiSession {
        try await eventually("Claude Code 会话上桥", timeout: .seconds(60)) { session(pid: pid) != nil }
        return session(pid: pid)!
    }

    /// 等这个会话在 `start` 之后做完一轮（进过工作、又歇下）：发话之前取 `start`。看变化记录，不看此刻的状态——
    /// 回放时一轮可能在开始等之前就做完了；按歇下的时刻认，之前停下的那一轮不算。
    func waitForTurn(_ id: PiSession.ID, since start: Date, timeout: Duration = .seconds(180)) async throws {
        func done() -> Bool {
            var worked = false
            for case .stateChanged(let session, _) in log.changes where session.id == id {
                if session.state.isWorking || session.state == .waitingForUser { worked = true }
                if worked && session.state == .settled && session.stateSince > start { return true }
            }
            return false
        }
        do {
            try await eventually("这一轮做完", timeout: timeout) { done() }
        } catch {
            throw Stuck(description: "等不到这一轮做完；会话：\(String(describing: bridge.session(id: id)?.state)) \(String(describing: bridge.session(id: id)?.detail)) \(String(describing: bridge.session(id: id)?.question))")
        }
    }

    /// 等这个会话弹出能从 CuePad 作答的问题；等不到时带上终端此刻的样子。
    func waitForQuestion(_ id: PiSession.ID, on terminal: ClaudeTerminal? = nil) async throws -> PiQuestion {
        do {
            try await eventually("会话在等你确认", timeout: .seconds(180)) { bridge.session(id: id)?.question?.promptID != nil }
        } catch {
            throw NoQuestion(description: "等不到会话在等你确认；会话：\(String(describing: bridge.session(id: id)))；终端：\n\(await terminal?.screen ?? "")")
        }
        return bridge.session(id: id)!.question!
    }

    /// 在终端里叫它用一个要确认的工具，等到它在等你确认。模型偶尔不照做（没调工具就答完了这一轮）：在同一会话里再说一次，只重来一次。
    func ask(_ prompt: String, on terminal: ClaudeTerminal, in id: PiSession.ID) async throws -> PiQuestion {
        for attempt in 0..<2 {
            try await terminal.type(prompt)
            var worked = false
            try await eventually("在等你确认或这一轮做完", timeout: .seconds(180)) {
                let session = bridge.session(id: id)
                if session?.state.isWorking == true { worked = true }
                return session?.question?.promptID != nil || (worked && session?.state == .settled)
            }
            if bridge.session(id: id)?.question?.promptID != nil || attempt == 1 { break }
        }
        return try await waitForQuestion(id, on: terminal)
    }

    /// 叫它同时派出一个后台子代理（前台跑约 8 秒命令）与一条 20 秒的后台命令，然后歇下；做完的各自由 Claude Code 再跑一轮交回。
    static let backgroundWork = "Do two things in one message, then stop. (1) Launch one subagent with the Agent tool: subagent_type general-purpose, "
        + "run_in_background true, description ticker, prompt: Run the Bash command `for i in 1 2; do sleep 4; done; echo SUB_DONE` as one foreground "
        + "Bash call (not run_in_background), then reply SUB_DONE. (2) Run a Bash command with run_in_background true: `sleep 20; echo BG_DONE`. "
        + "After launching both, reply only with the word launched and end your turn. Do not wait or poll. "
        + "Whenever a background task reports back later, reply only with the word it printed."

    /// 子代理交回中途结果后，名下的后台命令做完时它以同一 id 再跑一次、再交回。
    static let earlyReport = "Launch one subagent with the Agent tool: subagent_type general-purpose, run_in_background true, description nested, "
        + "prompt: Run one Bash command with run_in_background true: `sleep 15; echo NESTED`. Then immediately reply with just WAITING and end your turn. "
        + "Do not wait, poll, sleep or use Monitor. When that command reports back later, reply only with NESTED_DONE. "
        + "After launching the subagent, reply only with the word launched and end your turn. Do not wait or poll. "
        + "Whenever the subagent reports back later, reply only with the last word it said."
    /// 派一个要跑约一分钟的后台子代理，你再叫它停掉。
    static let longSubagent = "Launch one subagent with the Agent tool: subagent_type general-purpose, run_in_background true, description victim, "
        + "prompt: Run the Bash command `for i in $(seq 1 12); do sleep 5; done; echo V` as one foreground Bash call (not run_in_background), then reply V. "
        + "After launching it, reply only with the word launched and end your turn. Do not wait or poll."
    static let stopSubagent = "Stop the background subagent now with the TaskStop tool, then reply only STOPPED."
    static let passThrough = #""$REAL" "$@""#
    static let backgroundSettings = #"{"permissions": {"allow": ["Bash", "TaskStop"]}}"#

    /// 有后台工作的一件事：在飞时等子代理（至少 `waits` 段），最后交回结果的那一轮做完才歇下，只歇下一次；
    /// 歇下时的回答是那一轮的（含 `reply`），名册里只有一项、落在 `roster`。
    func expectSettledOnce(_ id: PiSession.ID, since start: Date, reply: String, roster: PiSubagentPhase, waits: Int = 1) async throws {
        let session = { [bridge] in bridge.session(id: id) }
        // 变化日志经异步流收下，比桥上的会话晚一拍：等它也收到这次歇下
        try await eventually("交回结果的那一轮做完", timeout: .seconds(240)) {
            session()?.state == .settled && (try? transcript(session()?.sessionFile))?.recap.lastReply?.contains(reply) == true
                && log.states.last == .settled
        }
        try await waitForDraftLanded(id)
        var states: [PiWorkState] = []
        for case .stateChanged(let changed, _) in log.changes where changed.id == id && changed.stateSince > start && changed.state != states.last {
            states.append(changed.state)
        }
        #expect(states.filter { $0 == .delegating }.count >= waits, "\(states)")
        #expect(states.filter { $0 == .settled } == [.settled] && states.last == .settled, "\(states)")
        #expect(states.dropLast().last?.isWorking == true && states.dropLast().last != .delegating, "歇下前是交回结果的那一轮：\(states)")
        #expect(session()?.subagents.map(\.phase) == [.known(roster)], "\(String(describing: session()?.subagents))")
        // 歇下就绪（`PiSessionState.answered`）：交回结果那一轮的收尾不早于它的开始（收到开它的 `task_notification` 的时刻）。
        // 只有连真 Agent 时可比：回放时 Mac 一侧的时刻随回放压缩，会话文件的时刻照录下的间隔
        if RealAgents.mode(of: .claudeCode) == .record {
            let turn = try #require(session()?.turnStartedAt), answered = try #require(try transcript(session()?.sessionFile).recap.answeredAt)
            #expect(turn <= answered, "\(turn) \(answered)")
        }
    }

    /// 会话文件此刻的对话（从头读）
    func transcript(_ file: URL?) throws -> PiHistoryUpdate {
        try PiHistory.index(file: try #require(file), agent: .claudeCode, from: nil, files: files)
    }

    /// 像 App 的索引器那样把会话文件读进会话索引（检查点里有会话名与首条消息）。
    func index(_ file: URL?) async throws {
        let update = try transcript(file)
        let session = IndexedSession(
            id: try #require(update.checkpoint.sessionID), path: update.file.path, cwd: work.path, lastActivityAt: .now, agent: .claudeCode)
        try await store.upsertPiSessions([PiSessionUpsert(session: session, checkpoint: try JSONEncoder().encode(update.checkpoint), transcript: nil)], host: "mac")
    }

    /// 这一轮的回答落了库，正在说的话就换下：没有了，或会话页认得出它已在对话里（`PiDraft.landed`，对着会话文件里最近一条回答）。
    /// 回答写进会话文件可能晚于这一轮歇下，等它落盘。
    func waitForDraftLanded(_ id: PiSession.ID) async throws {
        let file = bridge.session(id: id)?.sessionFile
        var newest: Date?
        try await eventually("回答落盘", timeout: .seconds(10)) {
            newest = (try? transcript(file))?.messages.last { $0.role == .known(.pi) }?.at
            return newest.map { $0 >= start(of: id) } ?? false
        }
        guard let draft = bridge.slots.first(where: { $0.id == id })?.draft else { return }
        #expect(draft.landed(newestReply: newest), "正在说的话起点 \(draft.since.timeIntervalSince1970)，最近一条回答 \(String(describing: newest?.timeIntervalSince1970))")
    }

    /// 这一轮开始（最近一次进入工作）的时刻
    private func start(of id: PiSession.ID) -> Date {
        log.changes.compactMap { if case .stateChanged(let session, _) = $0, session.id == id, session.state.isWorking { session.stateSince } else { nil } }
            .last ?? .distantPast
    }

    /// 像 App 的记录器那样记下桥上这个会话此刻的样子（状态与模型）。
    func record(_ id: PiSession.ID) async throws {
        let session = try #require(bridge.session(id: id))
        try await PiStateRecorder(store: store, hostID: "mac").update(
            sessionID: session.sessionID, state: session.state,
            modelState: PiModelState(model: session.model, thinking: session.thinking, models: session.availableModels), agent: .claudeCode)
    }

    /// 停掉起的 Claude Code 并等它们退出：都该自己收拾掉收件箱 socket（只有 SIGKILL 会让它留在 /tmp/cc-socks）。
    func stop() async {
        let pids = Set(terminals.map(\.pid) + bridge.sessions.filter { $0.agent == .claudeCode }.map(\.pid))
        for terminal in terminals { terminal.stop() }
        reading?.cancel()
        await runtime.stop()()
        hooks.stop()
        bridge.stop()
        guard AgentTape.current?.mode != .replay else { return }
        for pid in pids {
            try? await eventually("Claude Code \(pid) 退出") { kill(pid, 0) != 0 }
            #expect(!FileManager.default.fileExists(atPath: "/tmp/cc-socks/\(pid).sock"), "Claude Code \(pid) 的收件箱 socket 留下了")
        }
    }
}

struct TmuxFailed: Error { let command: String }
struct NoQuestion: Error, CustomStringConvertible { let description: String }
struct Stuck: Error, CustomStringConvertible { let description: String }

/// 私有 tmux 服务器里的一个 Claude Code（`exec claude`：pane 的进程就是 Claude Code）。
@MainActor
final class ClaudeTerminal {
    let pid: Int32
    private let server: Int32
    private let name: String

    init(testbed: ClaudeTestbed, arguments: [String]) async throws {
        name = "cpt-\(UUID().uuidString.prefix(8))"
        let environment = ProcessInfo.processInfo.environment.filter { key, _ in !["TMUX", "CLAUDE", "CUEPAD", "HERDR"].contains { key.hasPrefix($0) } }
            .merging(testbed.environment) { $1 }
        _ = try await Self.tmux(name, ["-f", "/dev/null", "new-session", "-d", "-x", "200", "-y", "50", "-c", testbed.work.path,
                                       (["exec", claudeURL!.path] + arguments).joined(separator: " ")], environment: environment)
        let ids = try await Self.tmux(name, ["display-message", "-p", "#{pane_pid} #{pid}"], environment: environment)
            .split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard ids.count == 2 else { throw TmuxFailed(command: "display-message") }
        pid = ids[0]
        server = ids[1]
    }

    @discardableResult
    private static func tmux(_ name: String, _ arguments: [String], environment: [String: String]) async throws -> String {
        guard let result = await ChildProcess.run(tmuxURL!, ["-L", name] + arguments, environment: environment, timeout: .seconds(10)),
              result.status == 0 else {
            throw TmuxFailed(command: arguments.joined(separator: " "))
        }
        return result.output
    }

    /// 在终端里打一句话，等它出现在输入框里再回车（一口气送进去的字被当作粘贴，紧跟着的回车会被吞掉）
    func type(_ text: String) async throws {
        try await Self.tmux(name, ["send-keys", "-l", text], environment: [:])
        try await eventually("输入框里有这句话") { await screen.contains(String(text.prefix(20))) }
        try await keys("Enter")
    }

    func keys(_ keys: String...) async throws { try await Self.tmux(name, ["send-keys"] + keys, environment: [:]) }

    var screen: String {
        get async { (try? await Self.tmux(name, ["capture-pane", "-p"], environment: [:])) ?? "" }
    }

    /// 像在终端里按 Ctrl-C 那样让它退出（它自己收拾收件箱 socket），再停掉这个 tmux 服务器。
    func stop() {
        kill(pid, SIGINT)
        kill(server, SIGTERM)
    }
}
#endif
