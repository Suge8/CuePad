#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CueBridge

/// 真 Claude Code（钉住的版本，`PinnedAgent.claude`）的端到端测试台：配置目录、HOME、XDG 目录、CuePad 的连接目录与资料库全部指到临时目录，
/// 绝不碰 ~/.claude 与真实资料库；模型是本测试台的假模型（`FakeModel`，Anthropic Messages，经 `ANTHROPIC_BASE_URL` 指过去），
/// 登录是假密钥、不带订阅令牌，辅助流量关掉（见 `environment`），零网络。
let pinnedClaude = PinnedAgent.claude
let claudeTestModel = ClaudeSandbox.model, claudeOtherModel = "sonnet"

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
    let bridge: Bridge
    let runtime: ClaudeCodeRuntime
    let files: AttachmentFiles
    let store: CueStore
    let log: ChangeLog

    /// 剧本只认带工具清单的请求（一轮真正的对话，含子代理的）：上面那类旁问的转录里也有你的话，不能让它们撞上剧本。
    func on(_ prompt: String, _ steps: FakeReply...) {
        model.on({ !$0.tools.isEmpty && $0.prompt.contains(prompt) }) { steps[min($0.step, steps.count - 1)] }
    }

    func on(_ prompt: String, reply: @escaping @Sendable (FakeRequest) -> FakeReply) {
        model.on({ !$0.tools.isEmpty && $0.prompt.contains(prompt) }, reply: reply)
    }

    func startConnected() throws { try runtime.start() }

    var integration: AgentIntegration {
        AgentIntegration(paths: paths, locate: { pinnedClaude.locator }, cuepad: PiProcess.cuepad, timing: noDeadline)
    }

    /// - Parameter settings: 用户自己的 settings.json（nil 是没有这个文件）。
    /// - Parameter wrapper: CuePad 起的 `claude` 换成这段 shell 脚本的外壳，真 claude 在 `$REAL`（`passThrough`：托管进程是它的子进程）。
    ///   脚本经 `TestScript` 放，内容里不写本次运行的路径：
    ///   它要用的文件放在 `wrapperDirectory`，脚本里写 `${0%/*}`。
    /// - Parameter signedIn: false 时不给密钥，Claude Code 照常起来、上桥，要用模型的都被它拒收。
    /// - Parameter timing: runtime 的钟（默认不前进：期限都不到点）；要量宽限的用例给 `ManualTiming`。
    /// - Parameter bridgeTiming: 桥的钟（闲置到点按它）
    init(
        settings: String? = nil, idleLimit: Duration = .seconds(1800), wrapper: String? = nil, signedIn: Bool = true,
        timing: Timing = noDeadline, bridgeTiming: Timing = .system
    ) async throws {
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
        try ClaudeSandbox.seed(config: config, trusting: work)
        if let settings { try Data(settings.utf8).write(to: config.appending(path: "settings.json")) }
        environment = ClaudeSandbox.environment(model: model, root: root, signedIn: signedIn)
            .merging(["CUEPAD_PI_SOCKET_DIR": sockets.path, "CUEPAD_LIBRARY_DIR": root.appending(path: "library").path]) { $1 }
        paths = AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
        store = try CueStore(location: .isolated(root.appending(path: "store", directoryHint: .isDirectory)))
        files = store.files
        bridge = Bridge(socketDirectory: sockets, hostedIdle: idleLimit, timing: bridgeTiming)
        log = ChangeLog(bridge)
        try bridge.start()
        var bin = pinnedClaude.bin
        if let wrapper {
            let real = bin.appending(path: "claude")
            bin = wrapperDirectory
            try TestScript.install("#!/bin/sh\n. \"$0.env\"\n\(wrapper)\n", at: bin.appending(path: "claude"), variables: ["REAL": real.path])
        }
        runtime = ClaudeCodeRuntime(
            bridge: bridge, paths: paths, store: store, claude: { [bin] in bin.appending(path: "claude") },
            locate: { [bin] in ExecutableLocator(searchDirectories: [bin]) }, timing: timing)
    }

    /// 搭好测试台跑 `body`，不论成败都停掉起的进程（临时目录随测试进程退出整体删除）。
    static func run(
        settings: String? = nil, idleLimit: Duration = .seconds(1800), wrapper: String? = nil, signedIn: Bool = true,
        timing: Timing = noDeadline, _ body: (ClaudeTestbed) async throws -> Void
    ) async throws {
        let testbed = try await ClaudeTestbed(
            settings: settings, idleLimit: idleLimit, wrapper: wrapper, signedIn: signedIn, timing: timing)
        do {
            try await body(testbed)
        } catch {
            await testbed.stop()
            throw error
        }
        await testbed.stop()
    }

    /// 同 `MacExecutor.connect`：桥上有这个会话就用它，没有就接着它。
    func connect(_ indexed: IndexedSession) async throws -> Session.ID {
        if let live = bridge.session(sessionID: indexed.id) { return live.id }
        return try await runtime.resume(indexed)
    }

    func record(_ id: Session.ID) async throws {
        let session = try #require(bridge.session(id: id))
        try await StateRecorder(store: store, hostID: "mac").update(
            sessionID: session.sessionID, state: session.state,
            modelState: ModelState(model: session.model, thinking: session.thinking, models: session.availableModels), agent: .claudeCode)
    }

    /// 停掉起的 Claude Code 并等它们退出：都该自己收拾掉收件箱 socket（只有 SIGKILL 会让它留在 /tmp/cc-socks）。
    /// 经外壳起的托管会话，会话的进程号是外壳的，收件箱跟着它底下的真 Claude Code 的进程号。
    func stop() async {
        let sessions = bridge.sessions.filter { $0.agent == .claudeCode }.map(\.pid)
        let pids = Set(sessions + sessions.flatMap { claudeChildren(of: $0) })
        await runtime.stop()()
        bridge.stop()
        for pid in pids {
            try? await eventually("Claude Code \(pid) 退出") { kill(pid, 0) != 0 }
            #expect(!FileManager.default.fileExists(atPath: "/tmp/cc-socks/\(pid).sock"), "Claude Code \(pid) 的收件箱 socket 留下了")
        }
    }
}

/// 外壳底下的真 Claude Code（钉住的那份）
func claudeChildren(of pid: pid_t) -> [pid_t] {
    var children = [pid_t](repeating: 0, count: 16)
    let count = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
    let claude = pinnedClaude.executable.resolvingSymlinksInPath().path
    return children.prefix(Int(max(count, 0))).filter { child in
        var path = [UInt8](repeating: 0, count: 4096)
        let length = proc_pidpath(child, &path, UInt32(path.count))
        return child > 0 && length > 0 && URL(filePath: String(decoding: path.prefix(Int(length)), as: UTF8.self)).resolvingSymlinksInPath().path == claude
    }
}

struct NoQuestion: Error, CustomStringConvertible { let description: String }
struct Stuck: Error, CustomStringConvertible { let description: String }
#endif
