#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

/// 托管会话是 CuePad 起的、一个会话一个进程的几家（`HostedProcesses`）：同一组收尾用例在各家上跑（`RealHostedEndTests`）。
enum Hosting: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case claude, codex, grok, dsh

    var testDescription: String { rawValue }

    var pinned: PinnedAgent {
        switch self {
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .dsh: .dsh
        }
    }

    /// 外壳只把起托管会话的那几次算进来；问在跑哪些会话（Claude Code）、问常驻服务（Codex）的照原样跑
    fileprivate var hostedLaunch: String {
        switch self {
        case .claude: #"[ "$1" != agents ]"#
        case .codex: #"[ "$2" = --listen ]"#
        case .grok, .dsh: "true"
        }
    }

    static var uncovered: String? { allCases.lazy.compactMap(\.pinned.uncovered).first }
}

/// 钉住的真 Agent（`PinnedAgent`）连本用例的假模型，起它的是外壳（`wrapper/<命令>`，真的在 `$REAL`）：
/// 记下每次起的进程号（`launched`），起的时候前面起的还活着就记进 `overlap`（同一会话同时两个进程）；
/// 起的那一刻有 `slow` 标记的，真 Agent 退出后（写 `eof.<进程号>`）还握着输出 3 秒；有 `stubborn` 标记的不理 SIGTERM、退出后一直握着输出。
/// 配置目录、家目录、连接目录全在临时目录里，不碰真实的配置与资料库。
@MainActor
final class EndRig {
    let hosting: Hosting
    /// 桥的钟：闲置到点只在 `idleOut` 拨它时（真钟上的短时限会在发话之后、Agent 报忙之前到点，负载高时就碰上）
    private let idle: ManualTiming
    private static let idleLimit: Duration = .seconds(60)
    let model: FakeModel
    let bridge: PiBridge
    let runtime: any AgentRuntime
    let work: URL
    let wrapper: URL
    private let root: URL
    private let modelKey: PiModelKey?
    private let claude: ClaudeTestbed?
    private let hooks: AgentHookServer?

    static func run(
        _ hosting: Hosting, timing: Timing, _ body: (EndRig) async throws -> Void
    ) async throws {
        let rig = try await EndRig(hosting, timing: timing)
        do { try await body(rig) } catch {
            await rig.stop()
            throw error
        }
        await rig.stop()
    }

    private init(_ hosting: Hosting, timing: Timing) async throws {
        self.hosting = hosting
        let idle = ManualTiming()
        self.idle = idle
        try hosting.pinned.require()
        let script = """
            dir=${0%/*}
            \(hosting.hostedLaunch) || exec "$REAL" "$@"
            for p in $(cat "$dir/launched" 2>/dev/null); do kill -0 "$p" 2>/dev/null && echo "$p" >> "$dir/overlap"; done
            echo $$ >> "$dir/launched"
            if [ -e "$dir/stubborn" ]; then trap '' TERM; "$REAL" "$@"; : > "$dir/eof.$$"; exec sleep 600; fi
            if [ -e "$dir/slow" ]; then "$REAL" "$@"; s=$?; : > "$dir/eof.$$"; sleep 3; exit $s; fi
            exec "$REAL" "$@"
            """
        if hosting == .claude {
            let testbed = try await ClaudeTestbed(idleLimit: Self.idleLimit, wrapper: script, timing: timing, bridgeTiming: idle.timing)
            try testbed.startConnected()
            (claude, root, model, bridge, runtime, work, wrapper, hooks, modelKey) =
                (testbed, testbed.root, testbed.model, testbed.bridge, testbed.runtime, testbed.work, testbed.wrapperDirectory, nil, nil)
            return
        }
        claude = nil
        root = try makeTempDirectory().resolvingSymlinksInPath()
        model = try await FakeModel()
        work = root.appending(path: "work", directoryHint: .isDirectory)
        wrapper = root.appending(path: "wrapper", directoryHint: .isDirectory)
        for name in ["work", "user", "home"] {
            try FileManager.default.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true)
        }
        try TestScript.install(
            "#!/bin/sh\n. \"$0.env\"\n\(script)\n", at: wrapper.appending(path: hosting.pinned.command),
            variables: ["REAL": hosting.pinned.executable.path])
        let sockets = root.appending(path: "s", directoryHint: .isDirectory)
        let pi = PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets)
        let executable = wrapper.appending(path: hosting.pinned.command)
        let locator = ExecutableLocator(searchDirectories: [wrapper, hosting.pinned.bin])
        bridge = PiBridge(socketDirectory: sockets, hostedIdle: Self.idleLimit, timing: idle.timing)
        try bridge.start()
        var hooks: AgentHookServer?
        switch hosting {
        case .codex:
            let home = root.appending(path: "codex", directoryHint: .isDirectory)
            try Self.configureCodex(home: home, model: model, work: work)
            let environment = hosting.pinned.environment(home: root.appending(path: "user"), [
                "CODEX_HOME": home.path, "CUEPAD_PI_SOCKET_DIR": sockets.path, "CUEPAD_FAKE_MODEL_KEY": "fake",
                "XDG_CONFIG_HOME": root.appending(path: "xdg/config").path, "XDG_STATE_HOME": root.appending(path: "xdg/state").path,
            ])
            let paths = AgentPaths(pi: pi, environment: environment)
            let server = AgentHookServer(path: paths.pi.hookSocket)
            try server.start()
            hooks = server
            let codex = CodexRuntime(
                bridge: bridge, paths: paths, hooks: server, codex: { executable }, locate: { locator }, presence: TestPresence(), timing: timing)
            try codex.start()
            runtime = codex
            modelKey = nil
        case .grok:
            let home = root.appending(path: "grok", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let environment = [
                "HOME": root.appending(path: "user").path, "GROK_HOME": home.path, "GROK_XAI_API_BASE_URL": "\(model.baseURL)/v1",
                "XAI_API_KEY": "fake-xai-key", "GROK_AUTH_PATH": home.appending(path: "no-login.json").path, "GROK_DISABLE_AUTOUPDATER": "1",
                "NO_PROXY": "127.0.0.1,localhost", "no_proxy": "127.0.0.1,localhost", "CUEPAD_PI_SOCKET_DIR": sockets.path,
            ]
            let grok = GrokRuntime(
                bridge: bridge, paths: AgentPaths(pi: pi, environment: environment), files: scratchFiles, grok: { executable }, locate: { locator },
                timing: timing)
            try grok.start()
            runtime = grok
            modelKey = nil
        default:
            let environment = hosting.pinned.environment(home: root.appending(path: "home"), [
                "DSH_HOME": root.appending(path: "dsh").path, "DEEPSEEK_API_KEY": "fake-key", "DEEPSEEK_BASE_URL": model.baseURL,
                "DEEPSEEK_SEARCH_BASE_URL": model.baseURL, "DSH_TELEMETRY_DISABLED": "1",
            ])
            runtime = DshRuntime(bridge: bridge, paths: AgentPaths(pi: pi, environment: environment), dsh: { executable }, locate: { locator }, timing: timing)
            modelKey = PiModelKey(provider: "deepseek-official", id: "deepseek-flash")
        }
        self.hooks = hooks
    }

    /// 假模型当提供方（Codex 只认配置目录里的），关掉联网的插件、应用、更新与遥测，信任工作目录。
    private static func configureCodex(home: URL, model: FakeModel, work: URL) throws {
        let text = """
            model_provider = "fake"
            model = "gpt-5.5"
            model_reasoning_effort = "low"
            approval_policy = "never"
            sandbox_mode = "workspace-write"
            check_for_update_on_startup = false

            [projects."\(work.path)"]
            trust_level = "trusted"

            [analytics]
            enabled = false

            [features]
            plugins = false
            apps = false
            browser_use = false
            computer_use = false
            remote_plugin = false
            plugin_discovery_prefetch = false

            [model_providers.fake]
            name = "fake"
            base_url = "\(model.baseURL)/v1"
            env_key = "CUEPAD_FAKE_MODEL_KEY"
            wire_api = "responses"

            """
        let daemon = home.appending(path: "app-server-daemon", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        try text.write(to: home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        try #"{"autoUpdateEnabled":false}"#.write(to: daemon.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    }

    /// 真 Agent 已退、外壳还握着的（`eof.<进程号>`，收尾没走到 SIGKILL 的红跑里留下）按确切进程号整组结束：`runtime.stop()` 的宽限
    /// 量在用例的钟上，不前进就一直等。
    func stop() async {
        for pid in launched where has("eof.\(pid)") && kill(pid, 0) == 0 { killpg(pid, SIGKILL) }
        if let claude { return await claude.stop() }
        await runtime.stop()()
        hooks?.stop()
        bridge.stop()
        model.stop()
        await TestProcesses.stop(under: [root])
        try? FileManager.default.removeItem(at: root)
    }

    /// 这个会话歇下、闲置计时起了，拨到点：桥请它退出（`idleOut` 之后外壳写下 `eof.<进程号>`）。
    func idleOut(_ id: PiSession.ID) async throws {
        let due = idle.now.addingTimeInterval(Self.idleLimit.seconds)
        try await eventually("歇下、闲置计时起了") { bridge.session(id: id)?.state == .settled && idle.hasSleeper(until: due) }
        idle.advance(Self.idleLimit)
    }

    func open() async throws -> PiSession.ID {
        try await runtime.open(in: work, launchToken: "t-\(UUID().uuidString)", name: nil, model: modelKey, thinking: nil)
    }

    /// 这句话的那一轮停在假模型里：先说半句，再不说完，直到 Agent 断开（停下这一轮）
    func hang(_ token: String) {
        model.on({ !$0.tools.isEmpty && $0.prompt.contains(token) }) { _ in .stream(["Working on it"]) }
    }

    func asked(_ token: String) -> Bool { model.requests.contains { !$0.tools.isEmpty && $0.prompt.contains(token) } }

    /// 发一句话、等它的回答落进会话记录（假模型的回答是 `ECHO <你的话>`），返回那时的会话。
    func converse(_ token: String, in id: PiSession.ID) async throws -> PiSession {
        try await bridge.send(PiMessage(text: token), to: id)
        let session = try #require(bridge.session(id: id))
        try await replied(token, in: session)
        return bridge.session(id: id) ?? session
    }

    func replied(_ token: String, in session: PiSession) async throws {
        try await eventually("\(token) 的回答落进会话记录") {
            (try? self.record(session))?.messages.contains { $0.role == .known(.pi) && $0.text.contains(token) } == true
        }
    }

    func record(_ session: PiSession) throws -> PiHistoryUpdate {
        try PiHistory.index(file: try #require(session.sessionFile), agent: session.agent, from: nil, files: scratchFiles)
    }

    func indexed(_ session: PiSession) -> IndexedSession {
        IndexedSession(id: session.sessionID, path: session.sessionFile?.path ?? "", cwd: work.path, lastActivityAt: .now, agent: session.agent)
    }

    /// 同 `MacExecutor.connect`：桥上有这个会话就用它，没有就接着它。
    func connect(_ indexed: IndexedSession) async throws -> PiSession.ID {
        if let live = bridge.session(sessionID: indexed.id) { return live.id }
        return try await runtime.resume(indexed)
    }

    func mark(_ name: String, _ on: Bool) throws {
        let file = wrapper.appending(path: name)
        if on { try Data().write(to: file) } else { try FileManager.default.removeItem(at: file) }
    }

    func has(_ name: String) -> Bool { FileManager.default.fileExists(atPath: wrapper.appending(path: name).path) }

    var launched: [Int32] { lines("launched").compactMap { Int32($0) } }
    var overlaps: [String] { lines("overlap") }

    private func lines(_ name: String) -> [String] {
        ((try? String(contentsOf: wrapper.appending(path: name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
#endif
