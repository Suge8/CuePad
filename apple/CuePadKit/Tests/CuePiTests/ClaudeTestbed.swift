#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 真 Claude Code 的端到端测试台：配置目录、HOME、XDG 目录、CuePad 的连接目录与资料库全部指到临时目录，绝不碰 ~/.claude 与真实资料库。
/// 模型走本机用户自己的 Claude 订阅（`haiku`，省额度）：OAuth 令牌约 1 小时过期、由 Pi 自动刷新，所以每搭一次测试台现从
/// ~/.pi/agent/auth.json 的 `anthropic.access` 读，只放进子进程环境（`CLAUDE_CODE_OAUTH_TOKEN`），不落盘。
/// 终端会话跑在私有 tmux 服务器里（`tmux -L`），结束时按确切 pid 停掉 Claude Code 与那个 tmux 服务器。
let claudeURL = ExecutableLocator.standard.candidates("claude").first
let tmuxURL = ExecutableLocator.standard.candidates("tmux").first
/// 此刻的订阅令牌（现读：Pi 会换新的）
private var claudeToken: String? {
    let auth = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent/auth.json")
    return (try? Data(contentsOf: auth)).flatMap(JSONValue.parse)?["anthropic"]?["access"]?.string
}
/// 真 Claude Code 的用例开了（`RealAgents`）、本机装了 claude、有订阅令牌
let realClaudeAvailable = RealAgents.on(.claudeCode) && claudeURL != nil && claudeToken != nil
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
    private var terminals: [ClaudeTerminal] = []
    private let store: CueStore

    var integration: AgentIntegration {
        AgentIntegration(paths: paths, locate: { ExecutableLocator(searchDirectories: [claudeURL!.deletingLastPathComponent()]) }, cuepad: PiProcess.cuepad)
    }

    /// - Parameter settings: 装钩子之前用户自己的 settings.json（nil 是没有这个文件）。
    /// - Parameter wrapped: CuePad 托管时起的 `claude` 是一层外壳、真 claude 是它的子进程（钩子的父进程不是 CuePad 起的那个）。
    init(installHooks: Bool = true, settings: String? = nil, idleLimit: Duration = .seconds(1800), wrapped: Bool = false) async throws {
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
        environment = [
            "CLAUDE_CONFIG_DIR": config.path, "HOME": root.appending(path: "home").path,
            "XDG_DATA_HOME": root.appending(path: "xdg-data").path, "XDG_STATE_HOME": root.appending(path: "xdg-state").path,
            "XDG_CACHE_HOME": root.appending(path: "xdg-cache").path, "XDG_CONFIG_HOME": root.appending(path: "xdg-config").path,
            "CUEPAD_PI_SOCKET_DIR": sockets.path, "CUEPAD_LIBRARY_DIR": root.appending(path: "library").path,
            "CLAUDE_CODE_OAUTH_TOKEN": claudeToken ?? "", "ANTHROPIC_API_KEY": "",
            // 不要自动记忆：叫它"记住"什么时它会先去翻记忆文件、要用 Bash，等你确认
            "ANTHROPIC_MODEL": claudeTestModel, "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
        ]
        paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
        store = try Fixture().store
        files = store.files
        bridge = PiBridge(socketDirectory: sockets, hostedIdle: idleLimit)
        try bridge.start()
        hooks = AgentHookServer(path: paths.pi.hookSocket)
        try hooks.start()
        let presence = TestPresence()
        self.presence = presence
        var bin = claudeURL!.deletingLastPathComponent()
        if wrapped {
            bin = root.appending(path: "wrapper", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let script = bin.appending(path: "claude")
            try "#!/bin/sh\n'\(claudeURL!.path)' \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }
        runtime = ClaudeCodeRuntime(
            bridge: bridge, paths: paths, hooks: hooks, store: store, locate: { [bin] in ExecutableLocator(searchDirectories: [bin]) },
            presence: presence)
        if installHooks { try await integration.install(.claudeCode) }
    }

    /// 搭好测试台跑 `body`，不论成败都收拾干净（停掉起的进程、删掉临时目录）。
    static func run(
        installHooks: Bool = true, settings: String? = nil, idleLimit: Duration = .seconds(1800), wrapped: Bool = false,
        _ body: (ClaudeTestbed) async throws -> Void
    ) async throws {
        let testbed = try await ClaudeTestbed(installHooks: installHooks, settings: settings, idleLimit: idleLimit, wrapped: wrapped)
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

    /// 等这个会话这一轮做完（进过工作、又歇下）。
    func waitForTurn(_ id: PiSession.ID, timeout: Duration = .seconds(180)) async throws {
        var worked = false
        do {
            try await eventually("这一轮做完", timeout: timeout) {
                let state = bridge.session(id: id)?.state
                if state?.isWorking == true || state == .waitingForUser { worked = true }
                return worked && state == .settled
            }
        } catch {
            throw Stuck(description: "等不到这一轮做完（进过工作：\(worked)）；会话：\(String(describing: bridge.session(id: id)?.state)) \(String(describing: bridge.session(id: id)?.detail)) \(String(describing: bridge.session(id: id)?.question))")
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

    /// 停掉起的 Claude Code 并等它们退出：都该自己收拾掉收件箱 socket（只有 SIGKILL 会让它留在 /tmp/cc-socks）。
    func stop() async {
        let pids = Set(terminals.map(\.pid) + bridge.sessions.filter { $0.agent == .claudeCode }.map(\.pid))
        for terminal in terminals { terminal.stop() }
        await runtime.stop()()
        hooks.stop()
        bridge.stop()
        for pid in pids {
            try? await eventually("Claude Code \(pid) 退出") { kill(pid, 0) != 0 }
            #expect(!FileManager.default.fileExists(atPath: "/tmp/cc-socks/\(pid).sock"), "Claude Code \(pid) 的收件箱 socket 留下了")
        }
        try? FileManager.default.removeItem(at: root)
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
