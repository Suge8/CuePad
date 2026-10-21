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
    let store: CueStore
    /// 桥上从测试台起来以后的全部变化
    let log: ChangeLog
    private var terminals: [ClaudeTerminal] = []
    /// 终端会话的会话文件跟读（同 App：历史索引读到的交给接入，`AgentRuntime.read`）；开第一个终端时起
    private var reading: Task<Void, Never>?

    /// 起接入并接终端里的会话：测试台装了钩子，同 App 检测出接入了（`follow(.all)`）。
    func startConnected() throws {
        try runtime.start()
        runtime.follow(.all)
    }

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
#endif
