#if os(macOS)
import AppKit
import CueAgent
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

/// App 装上真 Claude Code（钉住的版本，`ClaudeSandbox` 隔离、假模型回 `ECHO <你的话>`）的流程测试台：全部状态落在临时目录，不碰 ~/.claude。
/// 接入装好（`AgentIntegration.install`，CuePad 跟读全部会话），钩子调的 `cuepad` 不存在：钩子都不通，终端里的会话只经 `claude agents --json` 补上、没有收件箱令牌。
@MainActor
final class ClaudeRig {
    let root: URL
    let work: URL
    let bin: URL
    let environment: [String: String]
    private(set) var bridge: PiBridge
    private(set) var hooks: AgentHookServer
    private(set) var services: AppServices
    /// 起一个 App 实例（桥、钩子 socket、AppServices）：`relaunch` 再起一次，库、设置与 Claude Code 的目录都不变
    private let boot: () throws -> (PiBridge, AgentHookServer, AppServices)
    let model: FakeModel
    private var terminals: [Terminal] = []
    var store: CueStore { services.store }
    var runtime: ClaudeCodeRuntime { services.runtimes[.claudeCode] as! ClaudeCodeRuntime }

    /// - Parameter settings: Claude Code 的用户设置（配置目录里的 settings.json）
    /// - Parameter wrapper: CuePad 起的 `claude` 换成这段 sh 脚本，真的在 `$REAL`，脚本所在目录是 `bin`（经 `TestScript`，内容里不写本次运行的路径）
    /// - Parameter timing: App 与桥的钟；Claude Code 的接入用真钟（等终端会话起好）
    init(settings: String? = nil, wrapper: String? = nil, hostedIdle: Duration = AgentTimeouts.hostedIdle, timing: Timing = .system) async throws {
        try PinnedAgent.claude.require()
        root = TestLibraries.makeDirectory()
        let workDirectory = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        work = URL(filePath: ClaudeCode.realPath(workDirectory), directoryHint: .isDirectory)
        model = try await FakeModel()
        let config = root.appending(path: "config")
        let sockets = URL(filePath: "/tmp/crig-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        environment = ClaudeSandbox.environment(model: model, root: root).merging(["CUEPAD_PI_SOCKET_DIR": sockets.path]) { $1 }
        try ClaudeSandbox.seed(config: config, trusting: work)
        if let settings { try Data(settings.utf8).write(to: config.appending(path: "settings.json")) }
        let bin = wrapper == nil ? PinnedAgent.claude.bin : root.appending(path: "wrapper", directoryHint: .isDirectory)
        if let wrapper {
            try TestScript.install("#!/bin/sh\n. \"$0.env\"\n\(wrapper)\n", at: bin.appending(path: "claude"), variables: ["REAL": PinnedAgent.claude.executable.path])
        }
        self.bin = bin
        let paths = PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets, binDirectory: root.appending(path: "home/.local/bin"))
        // 其余 Agent 的目录也指到临时目录：不读这台 Mac 上真实的会话
        let agentPaths = AgentPaths(pi: paths, environment: environment.merging([
            "CODEX_HOME": root.appending(path: "codex").path, "OPENCODE_CONFIG_DIR": root.appending(path: "opencode").path,
            "GROK_HOME": root.appending(path: "grok").path, "CUEPAD_AGENTS_DIR": root.appending(path: "agents").path,
            "DSH_HOME": root.appending(path: "dsh").path,
        ]) { $1 })
        let helper = root.appending(path: "CuePad.app/Contents/Helpers/cuepad")
        let agents = AgentIntegration(paths: agentPaths, locate: { [bin] in ExecutableLocator(searchDirectories: [bin]) }, cuepad: helper)
        try await agents.install(.claudeCode)
        let location = try LibraryLocation.resolve(environment: [LibraryLocation.environmentKey: root.appending(path: "Library").path])
        let defaults = TempDefaults().defaults
        boot = { [root] in
            let bridge = PiBridge(socketDirectory: sockets, hostedIdle: hostedIdle, timing: timing)
            let hooks = AgentHookServer(path: paths.hookSocket)
            let mac = MacDependencies(
                pi: bridge, hotkeys: InMemoryHotkeys(), paths: agentPaths, agents: AgentIntegrations(agents), terminal: PiTerminalJumper(),
                hostID: TestApp.hostID, workspaces: Workspaces(root: root.appending(path: "CuePad", directoryHint: .isDirectory)),
                wakeNotifications: NotificationCenter(), timing: timing,
                commandLineTool: CommandLineToolInstaller(helper: helper, linkDirectory: root.appending(path: "home/.local/bin"), shellPath: { nil }),
                updater: nil, hooks: hooks,
                runtimes: { store in [.claudeCode: ClaudeCodeRuntime(
                    bridge: bridge, paths: agentPaths, hooks: hooks, store: store, claude: { bin.appending(path: "claude") },
                    locate: { ExecutableLocator(searchDirectories: [bin]) })] },
                pasteboard: NSPasteboard(name: .init("crig-\(UUID().uuidString)")),
                cue: CueDependencies(launch: { _, _ in nil }, helper: realPi, notifier: RecordingCueNotifier()))
            let services = try AppServices(location: location, defaults: defaults, sync: .custom(FakeSync()), mac: mac)
            LibraryLedger.tracking(services.store, createdAt: #_sourceLocation)
            return (bridge, hooks, services)
        }
        (bridge, hooks, services) = try boot()
    }

    /// 搭好、起 App 跑 `body`，不论成败都收掉起的进程（临时目录随测试进程退出整体删除）。`before` 在 App 起来之前做（先开着的终端会话）。
    static func run(
        settings: String? = nil, wrapper: String? = nil, hostedIdle: Duration = AgentTimeouts.hostedIdle, timing: Timing = .system,
        before: (ClaudeRig) async throws -> Void = { _ in }, _ body: (ClaudeRig) async throws -> Void
    ) async throws {
        let rig = try await ClaudeRig(settings: settings, wrapper: wrapper, hostedIdle: hostedIdle, timing: timing)
        do {
            try await before(rig)
            rig.services.start()
            try await body(rig)
        } catch {
            await rig.shutdown()
            throw error
        }
        await rig.shutdown()
    }

    /// 同退出 CuePad 再打开：这个实例的后台工作、执行器、接入、钩子与桥都停掉，再起一个新的（终端里的会话照常开着）。
    /// 返回时新实例已对完上次没收尾的请求（执行器先起好，`start` 里不再起第二遍）。
    func relaunch() async throws {
        await stopApp()
        (bridge, hooks, services) = try boot()
        try await services.executor.start()
        services.start()
    }

    private func stopApp() async {
        _ = await services.beginShutdown()()
    }

    /// 托管的进程按 runtime 的收法收；终端里的按 pid 结束；外壳在 `bin/pids` 里记下的（修坏了时 runtime 收不掉的那种）按 pid 结束。
    func shutdown() async {
        _ = await services.beginShutdown()()
        for terminal in terminals { terminal.stop() }
        let stray = ((try? String(contentsOf: bin.appending(path: "pids"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
        for pid in stray where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// 在私有 tmux 服务器里开一个终端会话（`arguments` 是 `claude` 的参数），等它起好（登记文件写下 `status`）。
    func terminal(_ arguments: [String]) async throws -> Terminal {
        let terminal = try await Terminal(rig: self, arguments: arguments)
        terminals.append(terminal)
        let registry = root.appending(path: "config/sessions/\(terminal.pid).json")
        try await eventually("终端里的 Claude Code 起好") {
            (try? Data(contentsOf: registry)).flatMap(JSONValue.parse)?["status"]?.string != nil
        }
        return terminal
    }

    func replies(of sessionID: String) async throws -> [String] {
        guard let indexed = try await store.piSession(sessionID) else { return [] }
        return Self.texts(in: URL(filePath: indexed.path), role: "assistant")
    }

    static func texts(in file: URL, role: String) -> [String] {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any], message["role"] as? String == role else { return nil }
            if let text = message["content"] as? String { return text }
            return (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
    }

    @MainActor
    final class Terminal {
        let pid: Int32
        private let server: Int32
        private let name: String

        init(rig: ClaudeRig, arguments: [String]) async throws {
            let name = "crig-\(UUID().uuidString.prefix(8))"
            let environment = PinnedAgent.claude.environment(home: rig.root.appending(path: "home"), rig.environment)
            try await Self.tmux(name, ["-f", "/dev/null", "new-session", "-d", "-x", "200", "-y", "50", "-c", rig.work.path,
                                       (["exec", PinnedAgent.claude.executable.path] + arguments).joined(separator: " ")], environment: environment)
            let ids = try await Self.tmux(name, ["display-message", "-p", "#{pane_pid} #{pid}"])
                .split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            try #require(ids.count == 2)
            (self.name, pid, server) = (name, ids[0], ids[1])
        }

        var screen: String { get async { (try? await Self.tmux(name, ["capture-pane", "-p"])) ?? "" } }

        /// 打一句话，等它出现在输入框里再回车（一口气送进去的字被当作粘贴，紧跟着的回车会被吞掉）
        func type(_ text: String) async throws {
            try await Self.tmux(name, ["send-keys", "-l", text])
            try await eventually("输入框里有这句话") { await screen.contains(String(text.prefix(20))) }
            try await Self.tmux(name, ["send-keys", "Enter"])
        }

        func stop() {
            kill(pid, SIGINT)
            kill(server, SIGTERM)
        }

        @discardableResult
        private static func tmux(_ name: String, _ arguments: [String], environment: [String: String] = [:]) async throws -> String {
            let tmux = try #require(ExecutableLocator.standard.candidates("tmux").first, "要 tmux")
            let result = try #require(await ChildProcess.run(tmux, ["-L", name] + arguments, environment: environment, timeout: .seconds(10)))
            try #require(result.status == 0, "tmux \(arguments.joined(separator: " "))")
            return result.output
        }
    }
}
#endif
