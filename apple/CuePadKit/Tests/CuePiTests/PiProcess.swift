#if os(macOS)
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePi

/// 真 Pi（钉住的版本，`PinnedAgent.pi`）的测试驱动，RPC 模式。所有状态落在临时目录：agent 目录（`PI_CODING_AGENT_DIR`）与家目录，
/// 绝不碰真实 ~/.pi；模型是本用例的假模型（`FakeModel`，经 agent 目录的 `models.json` 指过去，Chat Completions），零网络。
let pinnedPi = PinnedAgent.pi

/// FireCode（Pi 扩展，npm 的 `pi-firecode`）随 Pi 一起钉住装进缓存（`Tests/agents.json` 的 `with`）；
/// `CUEPAD_FIRECODE_SOURCE` 指向另一份 FireCode 检出时用它（验证还没合并的 FireCode 改动，入口是检出里的 `index.ts`）。
let firecodeEntry: URL = ProcessInfo.processInfo.environment["CUEPAD_FIRECODE_SOURCE"].map { URL(filePath: $0).appending(path: "index.ts") }
    ?? pinnedPi.bin.deletingLastPathComponent().appending(path: "node_modules/pi-firecode/dist/index.js")

private let fixtures = fixturesDirectory

struct PiEvent: @unchecked Sendable {
    let json: [String: Any]
    subscript(key: String) -> Any? { json[key] }
}

final class PiProcess: @unchecked Sendable {
    let root: URL
    let paths: PiPaths
    let cwd: URL
    let model: FakeModel
    var home: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    private let process = Process()
    private let stdin = Pipe()
    private let errPipe = Pipe()
    private struct Output {
        var events: [PiEvent] = []
        var pending = Data()
        var stderr = Data()
    }
    private let output = Mutex(Output())
    private let exited: Task<Void, Never>
    var stderr: String { output.withLock { String(decoding: $0.stderr, as: UTF8.self) } }

    var pid: Int32 { process.processIdentifier }
    var events: [PiEvent] { output.withLock { $0.events } }

    /// - Parameter installBridge: 先用安装器把桥扩展装进临时 agent 目录、技能装进临时家目录的 `.agents`，让 Pi 按自己的发现规则加载。
    /// - Parameter oneShotPrompt: 非 nil 时以 print 模式跑这条 prompt 然后退出（否则 RPC 常驻）。
    /// - Parameter firecode: 把 FireCode 与测试配置装进临时 agent 目录（它的子代理是进程内子会话，只加载 agent 目录里的扩展、只认 `models.json` 里的模型）。
    /// - Parameter alongside: 与它共用同一个临时 agent 目录、连接目录、工作目录与假模型（同一会话的第二个进程）。
    /// - Parameter discoverSkills: 让 Pi 去它的 skills 目录发现 skill（默认的安静参数里是 `--no-skills`）。
    /// - Parameter settings: 另外写进临时 agent 目录 Pi 设置（`settings.json`）的项，如压缩阈值（隔离的那几项见 `writeSettings`）。
    /// - Parameter model: 剧本要在 Pi 起来之前写好时（一起来就发请求的 print 模式）先建好交进来。
    init(installBridge: Bool = true, socketDirectory: URL? = nil, extraExtensions: [String] = ["ui-confirm.ts"],
         oneShotPrompt: String? = nil, firecode: Bool = false,
         alongside other: PiProcess? = nil, sessionFile: URL? = nil, env: [String: String] = [:], extraArguments: [String] = [], discoverSkills: Bool = false, settings: [String: Any]? = nil,
         model: FakeModel? = nil) async throws {
        try pinnedPi.require()
        let (exit, ended) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in ended.finish() }
        exited = Task { for await _ in exit {} }
        root = try other?.root ?? makeTempDirectory()
        cwd = root.appending(path: "work")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        paths = other?.paths ?? PiPaths(
            agentDirectory: root.appending(path: "agent"), socketDirectory: socketDirectory ?? root.appending(path: "s"), binDirectory: root.appending(path: "bin"))
        if let other {
            self.model = other.model
        } else {
            if let model { self.model = model } else { self.model = try await FakeModel() }
            try Self.writeModels(self.model, into: paths.agentDirectory)
            try Self.writeSettings(settings ?? [:], discoverSkills: discoverSkills, into: paths.agentDirectory)
            self.model.on({ $0.system.contains("single-line task title") }) { .say("\($0.model)：\($0.prompt)") }
            if installBridge {
                let agents = AgentIntegration(paths: AgentPaths(pi: paths, environment: ["CUEPAD_AGENTS_DIR": home.appending(path: ".agents").path]), locate: { pinnedPi.locator }, cuepad: Self.cuepad, timing: noDeadline)
                try await agents.install(.pi)
            }
        }
        if firecode { try Self.installFirecode(into: paths.agentDirectory) }

        var args = (oneShotPrompt.map { ["-p", $0] } ?? ["--mode", "rpc"]) + extraArguments
        if let sessionFile { args += ["--session", sessionFile.path] }
        for e in extraExtensions { args += ["-e", fixtures.appending(path: e).path] }

        var environment = pinnedPi.environment(home: home, [
            "PI_CODING_AGENT_DIR": paths.agentDirectory.path, "CUEPAD_PI_SOCKET_DIR": paths.socketDirectory.path, "PI_OFFLINE": "1",
            "TERM_PROGRAM": "test-term", "__CFBundleIdentifier": "com.example.term", "TMUX_PANE": "%9", "TMUX": "/tmp/tmux-test/default,1,0",
        ])
        environment.merge(env) { _, new in new }

        process.executableURL = pinnedPi.executable
        process.arguments = args
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = stdin
        let out = Pipe()
        process.standardOutput = out
        process.standardError = errPipe
        try process.run()
        if oneShotPrompt != nil { try stdin.fileHandleForWriting.close() } // print 模式会读 stdin 直到 EOF
        // 专用线程读到 EOF：readabilityHandler 在句柄被关闭后会抛 ObjC 异常
        Self.drain(out.fileHandleForReading) { [weak self] in self?.ingest($0) }
        Self.drain(errPipe.fileHandleForReading) { [weak self] data in self?.output.withLock { $0.stderr.append(data) } }
    }

    private final class Anchor {}
    static var cuepad: URL { Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appending(path: "cuepad") }

    /// 假模型的三个模型：标价 echo-b 最低、echo（缺省的当前模型）其次（起名挑同一 provider 里最便宜的）；echo-think 能思考，echo-b 不能看图。
    static func writeModels(_ model: FakeModel, into agent: URL) throws {
        func entry(_ id: String, reasoning: Bool = false, images: Bool = true, cost: (Double, Double)) -> [String: Any] {
            ["id": id, "name": id, "reasoning": reasoning, "input": images ? ["text", "image"] : ["text"], "contextWindow": 100_000, "maxTokens": 4096,
             "cost": ["input": cost.0, "output": cost.1, "cacheRead": 0, "cacheWrite": 0]]
        }
        let provider: [String: Any] = [
            "baseUrl": "\(model.baseURL)/v1", "api": "openai-completions", "apiKey": "fake",
            "models": [entry("echo", cost: (1, 2)), entry("echo-think", reasoning: true, cost: (3, 4)), entry("echo-b", images: false, cost: (0.1, 0.5))],
        ]
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["providers": ["fake": provider]], options: [.sortedKeys]).write(to: agent.appending(path: "models.json"))
    }

    /// 临时 agent 目录里的 Pi 设置（终端里起的与 CuePad 后台托管的都读它，同真实用户一样）：默认用假模型、不思考；
    /// 不加载自动发现的 skill，`discoverSkills` 时照常发现。上下文文件、提示词模板、主题只从 agent 目录与（受信任的）工作目录找，两处都是临时目录。
    private static func writeSettings(_ extra: [String: Any], discoverSkills: Bool, into agent: URL) throws {
        var settings: [String: Any] = ["defaultProvider": "fake", "defaultModel": "echo", "defaultThinkingLevel": "off"]
        if !discoverSkills { settings["skills"] = ["!**"] }
        settings.merge(extra) { $1 }
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]).write(to: agent.appending(path: "settings.json"))
    }

    private static func installFirecode(into agent: URL) throws {
        let fm = FileManager.default
        let firecode = agent.appending(path: "extensions/firecode")
        try fm.createDirectory(at: firecode, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: firecode.appending(path: "source"), withDestinationURL: firecodeEntry.deletingLastPathComponent())
        try #"export { default } from "./source/\#(firecodeEntry.lastPathComponent)";"#.write(to: firecode.appending(path: "index.ts"), atomically: true, encoding: .utf8)
        try fm.copyItem(at: fixtures.appending(path: "firecode-config.jsonc"), to: firecode.appending(path: "config.jsonc"))
    }

    struct FirecodeUnavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// 只看 Pi 事件的结构化字段，与 FireCode 的文案和语言无关。
    var subagentsToolFailed: Bool {
        events.contains { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "subagents" && $0["isError"] as? Bool == true }
    }

    /// 工具报错时带着 FireCode 启动时发的全部提示原文失败（拒绝原因就在其中），不让测试只说"子代理没出现"。
    func requireSubagentsTool() throws {
        guard subagentsToolFailed else { return }
        let notices = events.filter { $0["type"] as? String == "extension_ui_request" && $0["method"] as? String == "notify" }
            .compactMap { $0["message"] as? String }
        throw FirecodeUnavailable(description: "FireCode 没有加载指挥官（subagents 工具不可用）。FireCode 的提示原文：\(notices.isEmpty ? "（没有）" : notices.joined(separator: " | "))；测试配置见 Fixtures/firecode-config.jsonc")
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }

    deinit { stop() }

    private static func drain(_ handle: FileHandle, _ consume: @escaping @Sendable (Data) -> Void) {
        let fd = handle.fileDescriptor
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buffer, buffer.count) // 有多少读多少；FileHandle.read(upToCount:) 会等满
                if n <= 0 { break }
                consume(Data(buffer[0..<n]))
            }
            _ = handle // 读线程存活期间持有句柄，fd 不会被提前关闭
        }
    }

    private func ingest(_ data: Data) {
        output.withLock { output in
            output.pending.append(data)
            while let nl = output.pending.firstIndex(of: 0x0A) {
                let line = output.pending[output.pending.startIndex..<nl]
                output.pending = Data(output.pending[output.pending.index(after: nl)...])
                if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { output.events.append(PiEvent(json: json)) }
            }
        }
    }

    func send(_ command: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func prompt(_ text: String) throws { try send(["type": "prompt", "message": text]) }

    func waitUntilExit() async { await exited.value }

    func kill(_ signal: Int32) { Darwin.kill(process.processIdentifier, signal) }

    /// 这句话的那一轮停在假模型里，直到测试放行（`FakeGate.open`）或 Pi 停下这一轮；放行后照 `then` 答。
    func hold(_ prompt: String, then reply: FakeReply? = nil) -> FakeGate {
        let gate = model.gate()
        model.on({ $0.prompt.contains(prompt) }) { .held(gate, then: reply ?? .say("ECHO \($0.prompt)")) }
        return gate
    }

    func waitForEvent(_ what: String, _ match: @escaping @Sendable (PiEvent) -> Bool) async throws -> PiEvent {
        var found: PiEvent?
        try await eventually(what) {
            found = self.events.first(where: match)
            return found != nil
        }
        return found!
    }
}

extension PinnedAgent {
    var locator: ExecutableLocator { ExecutableLocator(searchDirectories: [bin]) }
}

let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
#endif
