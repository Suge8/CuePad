#if os(macOS)
import AppKit
import CueAgent
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad
@testable import CueBridge

/// App 装上真 Claude Code（钉住的版本，`ClaudeSandbox` 隔离、假模型回 `ECHO <你的话>`）的流程测试台：全部状态落在临时目录，不碰 ~/.claude。
@MainActor
final class ClaudeRig {
    let work: URL
    let bin: URL
    let bridge: Bridge
    let services: AppServices
    let model: FakeModel
    var store: CueStore { services.store }
    var runtime: ClaudeCodeRuntime { services.runtimes[.claudeCode] as! ClaudeCodeRuntime }

    /// - Parameter wrapper: CuePad 起的 `claude` 换成这段 sh 脚本，真的在 `$REAL`，脚本所在目录是 `bin`（经 `TestScript`，内容里不写本次运行的路径）
    init(wrapper: String? = nil, hostedIdle: Duration = AgentTimeouts.hostedIdle) async throws {
        try PinnedAgent.claude.require()
        let root = TestLibraries.makeDirectory()
        let workDirectory = root.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        work = URL(filePath: ClaudeCode.realPath(workDirectory), directoryHint: .isDirectory)
        model = try await FakeModel()
        let sockets = URL(filePath: "/tmp/crig-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let environment = ClaudeSandbox.environment(model: model, root: root).merging(["CUEPAD_PI_SOCKET_DIR": sockets.path]) { $1 }
        try ClaudeSandbox.seed(config: root.appending(path: "config"), trusting: work)
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
        let bridge = Bridge(socketDirectory: sockets, hostedIdle: hostedIdle)
        let mac = MacDependencies(
            bridge: bridge, hotkeys: InMemoryHotkeys(), paths: agentPaths, agents: AgentIntegrations(agents),
            hostID: TestApp.hostID, workspaces: Workspaces(root: root.appending(path: "CuePad", directoryHint: .isDirectory)),
            wakeNotifications: NotificationCenter(), timing: .system,
            commandLineTool: CommandLineToolInstaller(helper: helper, linkDirectory: root.appending(path: "home/.local/bin"), shellPath: { nil }),
            updater: nil, hooks: AgentHookServer(path: paths.hookSocket),
            runtimes: { store in [.claudeCode: ClaudeCodeRuntime(
                bridge: bridge, paths: agentPaths, store: store, claude: { bin.appending(path: "claude") },
                locate: { ExecutableLocator(searchDirectories: [bin]) })] },
            pasteboard: NSPasteboard(name: .init("crig-\(UUID().uuidString)")),
            cue: CueDependencies(launch: { _, _ in nil }, helper: realPi, notifier: RecordingCueNotifier()))
        services = try AppServices(location: location, defaults: TempDefaults().defaults, sync: .custom(FakeSync()), mac: mac)
        LibraryLedger.tracking(services.store, createdAt: #_sourceLocation)
        self.bridge = bridge
    }

    /// 搭好、起 App 跑 `body`，不论成败都收掉起的进程（临时目录随测试进程退出整体删除）。
    static func run(wrapper: String? = nil, hostedIdle: Duration = AgentTimeouts.hostedIdle, _ body: (ClaudeRig) async throws -> Void) async throws {
        let rig = try await ClaudeRig(wrapper: wrapper, hostedIdle: hostedIdle)
        do {
            rig.services.start()
            try await body(rig)
        } catch {
            await rig.shutdown()
            throw error
        }
        await rig.shutdown()
    }

    /// 托管的进程按 runtime 的收法收；外壳在 `bin/pids` 里记下的（修坏了时 runtime 收不掉的那种）按 pid 结束。
    func shutdown() async {
        let followers = services.cancelBackgroundWork()
        _ = await services.beginShutdown()()
        await followers?.value
        let stray = ((try? String(contentsOf: bin.appending(path: "pids"), encoding: .utf8)) ?? "").split(separator: "\n").compactMap { Int32($0) }
        for pid in stray where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    func replies(of sessionID: String) async throws -> [String] {
        guard let indexed = try await store.indexedSession(sessionID) else { return [] }
        let text = (try? String(contentsOf: URL(filePath: indexed.path), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any], message["role"] as? String == "assistant" else { return nil }
            if let text = message["content"] as? String { return text }
            return (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        }
    }
}
#endif
