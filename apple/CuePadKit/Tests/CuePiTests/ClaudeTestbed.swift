#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 真 Claude Code（钉住的版本，`PinnedAgent.claude`）的端到端测试台：配置目录、HOME、XDG 目录、CuePad 的连接目录与资料库全部指到临时目录，
/// 绝不碰 ~/.claude 与真实资料库；模型是本测试台的假模型（`FakeModel`，Anthropic Messages，经 `ANTHROPIC_BASE_URL` 指过去），
/// 登录是假密钥、不带订阅令牌，辅助流量关掉（见 `environment`），零网络。
/// 终端会话跑在私有 tmux 服务器里（`tmux -L`），结束时按确切 pid 停掉 Claude Code 与那个 tmux 服务器。
let pinnedClaude = PinnedAgent.claude
/// 录像框架登记各家可执行文件用的名字（`AgentTape.realExecutables`）：框架整体删除前不动它，Claude 已没有录像带
let claudeURL: URL? = pinnedClaude.executable
let tmuxURL = ExecutableLocator.standard.candidates("tmux").first
let claudeTestModel = "haiku", claudeOtherModel = "sonnet"

/// 256×256 纯红 PNG（32×32 的常被模型认成别的颜色）
let redPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAQAAAAEACAIAAADTED8xAAAB+0lEQVR42u3TQQkAAAjAwPUvrX8reHAJBmsK3pIAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwABgADAAGAAMAAYAA4ABwAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgAJMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAyAASTAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAYAAwABgADgAHAAGAAMAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADAAGAAOAAcAAYAAwABgADADHAllMDvLkz2XNAAAAAElFTkSuQmCC")!

@MainActor
final class ClaudeTestbed {
    let root: URL
    let wrapperDirectory: URL
    let config: URL
    /// 工作目录（真实路径：Claude Code 记的就是它）
    let work: URL
    let sockets: URL
    let environment: [String: String]
    let model: FakeModel
    let paths: AgentPaths
    let bridge: PiBridge
    let hooks: AgentHookServer
    let runtime: ClaudeCodeRuntime
    let presence: TestPresence
    let files: AttachmentFiles
    let store: CueStore
    let log: ChangeLog
    private var terminals: [ClaudeTerminal] = []
    private var reading: Task<Void, Never>?

    /// 起 Claude Code 用的环境：配置目录、HOME、XDG 目录都在 `root` 里（目录已建好），模型是 `model`。
    /// 模型地址只管 /v1/messages：fast mode 检查、WebFetch 的安全检查等不经它，所以关掉非必要流量，再清掉订阅登录、别的认证通道与代理。
    static func isolatedEnvironment(model: FakeModel, root: URL, signedIn: Bool = true) -> [String: String] {
        for name in ["config", "home", "xdg-data", "xdg-state", "xdg-cache", "xdg-config"] {
            try? FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        return [
            "CLAUDE_CONFIG_DIR": root.appending(path: "config").path, "HOME": root.appending(path: "home").path,
            "XDG_DATA_HOME": root.appending(path: "xdg-data").path, "XDG_STATE_HOME": root.appending(path: "xdg-state").path,
            "XDG_CACHE_HOME": root.appending(path: "xdg-cache").path, "XDG_CONFIG_HOME": root.appending(path: "xdg-config").path,
            "ANTHROPIC_BASE_URL": model.baseURL, "ANTHROPIC_API_KEY": signedIn ? apiKey : "",
            "CLAUDE_CODE_OAUTH_TOKEN": "", "ANTHROPIC_AUTH_TOKEN": "", "CLAUDE_CODE_USE_BEDROCK": "", "CLAUDE_CODE_USE_VERTEX": "", "CLAUDE_CODE_USE_FOUNDRY": "",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1",
            // 关了非必要流量，终端里的它照样去 downloads.claude.ai 装官方插件市场（2.1.318 经记录 CONNECT 的本机代理实测，每个进程一次）
            "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
            "HTTP_PROXY": "", "HTTPS_PROXY": "", "ALL_PROXY": "", "http_proxy": "", "https_proxy": "", "all_proxy": "",
            "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost",
            // 不要自动记忆：叫它"记住"什么时它会先去翻记忆文件、要用 Bash，等你确认
            "ANTHROPIC_MODEL": claudeTestModel, "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
        ]
    }

    static let apiKey = "sk-ant-api03-cuepad-test-key-not-real-00000000"

    /// 剧本只认带工具清单的请求（一轮真正的对话，含子代理的）：上面那类旁问的转录里也有你的话，不能让它们撞上剧本。
    func on(_ prompt: String, _ steps: FakeReply...) {
        model.on({ !$0.tools.isEmpty && $0.prompt.contains(prompt) }) { steps[min($0.step, steps.count - 1)] }
    }

    func on(_ prompt: String, reply: @escaping @Sendable (FakeRequest) -> FakeReply) {
        model.on({ !$0.tools.isEmpty && $0.prompt.contains(prompt) }, reply: reply)
    }

    func startConnected() throws {
        try runtime.start()
        runtime.follow(.all)
    }

    var integration: AgentIntegration {
        AgentIntegration(paths: paths, locate: { pinnedClaude.locator }, cuepad: PiProcess.cuepad, timing: noDeadline)
    }

    /// - Parameter settings: 装钩子之前用户自己的 settings.json（nil 是没有这个文件）。
    /// - Parameter wrapper: CuePad 起的 `claude` 换成这段 shell 脚本的外壳，真 claude 在 `$REAL`（`passThrough`：托管进程是它的子进程，
    ///   钩子的父进程不是 CuePad 起的那个）。终端里开的仍是真 claude。脚本经 `TestScript` 放，内容里不写本次运行的路径：
    ///   它要用的文件放在 `wrapperDirectory`，脚本里写 `${0%/*}`。
    /// - Parameter signedIn: false 时不给密钥，Claude Code 照常起来、上桥，要用模型的都被它拒收。
    init(installHooks: Bool = true, settings: String? = nil, idleLimit: Duration = .seconds(1800), wrapper: String? = nil, signedIn: Bool = true) async throws {
        try pinnedClaude.require()
        model = try await FakeModel()
        // auto 模式下没有明文放行的工具，Claude Code 先拿这一步问模型（不带工具清单）一个危害等级；答不出它就拦下这一步
        model.on({ $0.tools.isEmpty && $0.prompt.contains("<severity>N</severity>") }) { _ in .say("<severity>0</severity>") }
        root = try makeTempDirectory()
        wrapperDirectory = root.appending(path: "wrapper", directoryHint: .isDirectory)
        config = root.appending(path: "config")
        sockets = root.appending(path: "s")
        let workDirectory = root.appending(path: "work")
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        work = URL(filePath: ClaudeCode.realPath(workDirectory), directoryHint: .isDirectory)
        for name in ["config", "library"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        // 跳过首次启动的引导、"信任这个目录"与"用这个密钥吗"的询问
        let seed: JSONValue = [
            "hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true, "projects": .object([work.path: ["hasTrustDialogAccepted": true]]),
            "customApiKeyResponses": ["approved": [.string(String(Self.apiKey.suffix(20)))], "rejected": []],
        ]
        try seed.data.write(to: config.appending(path: ".claude.json"))
        if let settings { try Data(settings.utf8).write(to: config.appending(path: "settings.json")) }
        environment = Self.isolatedEnvironment(model: model, root: root, signedIn: signedIn)
            .merging(["CUEPAD_PI_SOCKET_DIR": sockets.path, "CUEPAD_LIBRARY_DIR": root.appending(path: "library").path]) { $1 }
        paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
        store = try CueStore(location: .isolated(root.appending(path: "store", directoryHint: .isDirectory)))
        files = store.files
        bridge = PiBridge(socketDirectory: sockets, hostedIdle: idleLimit)
        log = ChangeLog(bridge)
        try bridge.start()
        hooks = AgentHookServer(path: paths.pi.hookSocket)
        try hooks.start()
        let presence = TestPresence()
        self.presence = presence
        var bin = pinnedClaude.bin
        if let wrapper {
            let real = bin.appending(path: "claude")
            bin = wrapperDirectory
            try TestScript.install("#!/bin/sh\n. \"$0.env\"\n\(wrapper)\n", at: bin.appending(path: "claude"), variables: ["REAL": real.path])
        }
        runtime = ClaudeCodeRuntime(
            bridge: bridge, paths: paths, hooks: hooks, store: store, claude: { [bin] in bin.appending(path: "claude") },
            locate: { [bin] in ExecutableLocator(searchDirectories: [bin]) },
            presence: presence, timing: noDeadline)
        if installHooks { try await integration.install(.claudeCode) }
    }

    /// 搭好测试台跑 `body`，不论成败都停掉起的进程（临时目录随测试进程退出整体删除）。
    static func run(
        installHooks: Bool = true, settings: String? = nil, idleLimit: Duration = .seconds(1800), wrapper: String? = nil, signedIn: Bool = true,
        _ body: (ClaudeTestbed) async throws -> Void
    ) async throws {
        let testbed = try await ClaudeTestbed(installHooks: installHooks, settings: settings, idleLimit: idleLimit, wrapper: wrapper, signedIn: signedIn)
        do {
            try await body(testbed)
        } catch {
            await testbed.stop()
            throw error
        }
        await testbed.stop()
    }

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

    func session(pid: Int32) -> PiSession? { bridge.sessions.first { $0.pid == pid && $0.agent == .claudeCode } }

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
        for pid in pids {
            try? await eventually("Claude Code \(pid) 退出") { kill(pid, 0) != 0 }
            #expect(!FileManager.default.fileExists(atPath: "/tmp/cc-socks/\(pid).sock"), "Claude Code \(pid) 的收件箱 socket 留下了")
        }
    }
}

struct TmuxFailed: Error { let command: String }
struct NoQuestion: Error, CustomStringConvertible { let description: String }
struct Stuck: Error, CustomStringConvertible { let description: String }

@MainActor
final class ClaudeTerminal {
    let pid: Int32
    private let server: Int32
    private let name: String

    init(testbed: ClaudeTestbed, arguments: [String]) async throws {
        name = "cpt-\(UUID().uuidString.prefix(8))"
        let environment = pinnedClaude.environment(home: testbed.root.appending(path: "home"), testbed.environment)
        _ = try await Self.tmux(name, ["-f", "/dev/null", "new-session", "-d", "-x", "200", "-y", "50", "-c", testbed.work.path,
                                       (["exec", pinnedClaude.executable.path] + arguments).joined(separator: " ")], environment: environment)
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

    /// 在终端里的对话框上按键。对话框刚弹出的一小会儿里 Claude Code 不认按键（防误触；2.1.318 实测弹出后 10 毫秒按的 Enter 被吞掉，
    /// 3 秒后再按就生效）：对话框还在画面上就再按，直到 `done`。只在对话框还在时补按，按早了也不会落到输入框里。
    func press(_ key: String, on dialog: String, until done: () async throws -> Bool) async throws {
        try await eventually("终端里按 \(key) 生效") {
            if try await done() { return true }
            if await screen.contains(dialog) { try await keys(key) }
            try await Task.sleep(for: .milliseconds(300))
            return try await done()
        }
    }

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
