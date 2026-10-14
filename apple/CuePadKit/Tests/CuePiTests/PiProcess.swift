#if os(macOS)
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePi

/// 真实 Pi（`~/.local/bin/pi`，RPC 模式）的测试驱动。
/// 所有状态落在临时 agent 目录（`PI_CODING_AGENT_DIR`），绝不碰真实 ~/.pi；模型是假模型扩展，零网络。
let realPiURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pi")
/// 真 Pi 的用例开了（`RealAgents`）且本机装了 Pi
let realPiAvailable = RealAgents.on(.pi) && FileManager.default.isExecutableFile(atPath: realPiURL.path)

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

/// 本机装的 FireCode（用户的 Pi 扩展）源码；只读，测试里软链进临时 agent 目录。`CUEPAD_FIRECODE_SOURCE` 指向另一份 FireCode 检出时用它（验证还没合并的 FireCode 改动）。
let firecodeSource = (ProcessInfo.processInfo.environment["CUEPAD_FIRECODE_SOURCE"].map { URL(filePath: $0) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent/extensions/firecode/source")).resolvingSymlinksInPath()
let firecodeAvailable = FileManager.default.fileExists(atPath: firecodeSource.appending(path: "index.ts").path)

struct PiEvent: @unchecked Sendable {
    let json: [String: Any]
    subscript(key: String) -> Any? { json[key] }
}

final class PiProcess: @unchecked Sendable {
    let root: URL
    private let ownsRoot: Bool
    let paths: PiPaths
    let cwd: URL
    private let process = Process()
    private let stdin = Pipe()
    private let errPipe = Pipe()
    /// 两条读线程写、测试读的输出。
    private struct Output {
        var events: [PiEvent] = []
        var pending = Data()
        var stderr = Data()
    }
    private let output = Mutex(Output())
    /// 进程退出时结束（`terminationHandler`）：等退出就等它，不轮询。
    private let exited: Task<Void, Never>
    /// Pi 的 stderr（诊断用）
    var stderr: String { output.withLock { String(decoding: $0.stderr, as: UTF8.self) } }

    var pid: Int32 { process.processIdentifier }
    var events: [PiEvent] { output.withLock { $0.events } }

    /// - Parameter installBridge: 先用安装器把桥扩展装进临时 agent 目录，让 Pi 按自己的发现规则加载。
    /// - Parameter oneShotPrompt: 非 nil 时以 print 模式跑这条 prompt 然后退出（否则 RPC 常驻）。
    /// - Parameter firecode: 把本机 FireCode 与测试配置装进临时 agent 目录。它的子代理是进程内子会话，只加载 agent 目录里的扩展、
    ///   只认 `models.json` 里的模型，所以假模型也改为装进 agent 目录，并在 `models.json` 里登记。
    /// - Parameter modelInAgentDirectory: 假模型装进 agent 目录（不用 `-e` 加载）：CuePad 在后台托管的 Pi 只加载 agent 目录里的扩展。
    /// - Parameter alongside: 与它共用同一个临时 agent 目录、连接目录与工作目录（同一会话的第二个进程）；结束时不删共用的目录。
    /// - Parameter sessionFile: 用 `--session` 打开这个会话文件。
    /// - Parameter discoverSkills: 让 Pi 去它的 skills 目录发现 skill（默认的安静参数里是 `--no-skills`）。
    /// - Parameter settings: 写进临时 agent 目录的 Pi 设置（`settings.json`），如压缩阈值。
    init(installBridge: Bool = true, socketDirectory: URL? = nil, extraExtensions: [String] = ["ui-confirm.ts"],
         oneShotPrompt: String? = nil, firecode: Bool = false, modelInAgentDirectory: Bool = false,
         alongside other: PiProcess? = nil, sessionFile: URL? = nil, env: [String: String] = [:], extraArguments: [String] = [], discoverSkills: Bool = false, settings: [String: Any]? = nil) async throws {
        ownsRoot = other == nil
        let (exit, ended) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in ended.finish() }
        exited = Task { for await _ in exit {} }
        root = try other?.root ?? makeTempDirectory()
        cwd = root.appending(path: "work")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        paths = other?.paths ?? PiPaths(
            agentDirectory: root.appending(path: "agent"), socketDirectory: socketDirectory ?? root.appending(path: "s"), binDirectory: root.appending(path: "bin"))
        if installBridge && other == nil {
            let agents = AgentIntegration(
                paths: AgentPaths(pi: paths, environment: [:]), locate: { ExecutableLocator(searchDirectories: [realPiURL.deletingLastPathComponent()]) }, cuepad: Self.cuepad)
            try await agents.install(.pi)
        }

        if let settings {
            try FileManager.default.createDirectory(at: paths.agentDirectory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: settings).write(to: paths.agentDirectory.appending(path: "settings.json"))
        }
        if firecode { try Self.installFirecode(into: paths.agentDirectory) }
        if modelInAgentDirectory { try Self.installFakeModel(into: paths.agentDirectory) }
        let modelLoaded = firecode || modelInAgentDirectory || other != nil

        var args = (oneShotPrompt.map { ["-p", $0] } ?? ["--mode", "rpc"]) + Self.quietArguments.filter { !(discoverSkills && $0 == "--no-skills") }
        args += extraArguments
        if let sessionFile { args += ["--session", sessionFile.path] }
        if !modelLoaded { args += ["-e", fixtures.appending(path: "fake-model.ts").path] }
        for e in extraExtensions { args += ["-e", fixtures.appending(path: e).path] }

        // 不继承跑测试的环境里的终端复用器与 CuePad 变量：在 CuePad 托管的 Pi 会话里跑测试时，CUEPAD_HOSTED 会让这里起的每个 Pi 都自认是托管的
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in !["HERDR", "TMUX", "CUEPAD_"].contains { key.hasPrefix($0) } }
        environment["PI_CODING_AGENT_DIR"] = paths.agentDirectory.path
        environment["CUEPAD_PI_SOCKET_DIR"] = paths.socketDirectory.path
        environment["TERM_PROGRAM"] = "test-term"
        environment["__CFBundleIdentifier"] = "com.example.term"
        environment["TMUX_PANE"] = "%9"
        environment["TMUX"] = "/tmp/tmux-test/default,1,0"
        environment.merge(env) { _, new in new }

        process.executableURL = realPiURL
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

    /// 与测试包同一个产物目录里构建好的 `cuepad` 命令行（`swift test` 会把它一起构建）。
    private final class Anchor {}
    static var cuepad: URL { Bundle(for: Anchor.self).bundleURL.deletingLastPathComponent().appending(path: "cuepad") }

    /// 不联网、不读用户配置的参数，用假模型（测试里 CuePad 在后台托管的 Pi 也带这些，见 `PiRuntime` 的 `extraArguments`）。
    static let quietArguments = [
        "--offline", "--no-context-files", "--no-skills", "--no-prompt-templates", "--no-themes", "--model", "fake/echo", "--thinking", "off",
    ]

    private static func installFakeModel(into agent: URL) throws {
        let fm = FileManager.default
        let extensions = agent.appending(path: "extensions")
        try fm.createDirectory(at: extensions, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: extensions.appending(path: "fake-model.ts").path) {
            try fm.copyItem(at: fixtures.appending(path: "fake-model.ts"), to: extensions.appending(path: "fake-model.ts"))
        }
    }

    private static func installFirecode(into agent: URL) throws {
        let fm = FileManager.default
        let extensions = agent.appending(path: "extensions")
        let firecode = extensions.appending(path: "firecode")
        try fm.createDirectory(at: firecode, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: firecode.appending(path: "source"), withDestinationURL: firecodeSource)
        try #"export { default } from "./source/index.ts";"#.write(to: firecode.appending(path: "index.ts"), atomically: true, encoding: .utf8)
        try fm.copyItem(at: fixtures.appending(path: "firecode-config.jsonc"), to: firecode.appending(path: "config.jsonc"))
        try fm.copyItem(at: fixtures.appending(path: "fake-model.ts"), to: extensions.appending(path: "fake-model.ts"))
        try fm.copyItem(at: fixtures.appending(path: "fake-models.json"), to: agent.appending(path: "models.json"))
    }

    struct FirecodeUnavailable: Error, CustomStringConvertible {
        let description: String
    }

    /// 指挥官的 `subagents` 工具调用报了错：FireCode 没把指挥官加载起来（配置被它拒绝、开关或字段名跟不上它的版本……）。
    /// 只看 Pi 事件的结构化字段，与 FireCode 的文案和语言无关。
    var subagentsToolFailed: Bool {
        events.contains { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "subagents" && $0["isError"] as? Bool == true }
    }

    /// 工具报错时带着 FireCode 启动时发的全部提示原文失败（拒绝原因就在其中），不让测试只说"子代理没出现"。
    func requireSubagentsTool() throws {
        guard subagentsToolFailed else { return }
        let notices = events.filter { $0["type"] as? String == "extension_ui_request" && $0["method"] as? String == "notify" }
            .compactMap { $0["message"] as? String }
        throw FirecodeUnavailable(description: "本机 FireCode 没有加载指挥官（subagents 工具不可用）。FireCode 的提示原文：\(notices.isEmpty ? "（没有）" : notices.joined(separator: " | "))；测试配置见 Fixtures/firecode-config.jsonc")
    }

    func stop() {
        if process.isRunning { process.terminate() }
        if ownsRoot { try? FileManager.default.removeItem(at: root) }
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

    /// 假模型的停住与放行（`[[slow]]`、`[[slow-compact]]`，见 Fixtures/fake-model.ts）：窗口多长由测试定，不按时长。
    private var gate: URL { paths.agentDirectory.appending(path: "fake-model-gate", directoryHint: .isDirectory) }
    private let heldSeen = Mutex(0)

    private func heldCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: gate.path)) ?? []).filter { $0.hasPrefix("held-") }.count
    }

    /// 等到假模型又停住了一次（扩展已加载、请求已到模型）。
    func waitUntilHeld() async throws {
        let wanted = heldSeen.withLock { $0 += 1; return $0 }
        try await eventually("假模型停住") { self.heldCount() >= wanted }
    }

    /// 之后每次停住都放行，不关心停几次（压缩会发一到两次摘要请求，子代理的回复又带着标记）：返回的任务在不再需要时取消。
    func releaseEveryHold() -> Task<Void, any Error> {
        Task {
            while true {
                try await waitUntilHeld()
                try release()
            }
        }
    }

    /// 放行一次停住（先放后停也算）。
    func release() throws {
        try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
        try Data().write(to: gate.appending(path: "release-\(UUID().uuidString)"))
    }

    /// 等到某条 Pi 事件（stdout 上的 JSON 行）出现
    func waitForEvent(_ what: String, _ match: @escaping @Sendable (PiEvent) -> Bool) async throws -> PiEvent {
        var found: PiEvent?
        try await eventually(what) {
            found = self.events.first(where: match)
            return found != nil
        }
        return found!
    }
}

// 1×1 红色 PNG
let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
#endif
