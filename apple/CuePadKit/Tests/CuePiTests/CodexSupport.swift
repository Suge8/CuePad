#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import ImageIO
import Synchronization
import Testing
@testable import CuePi

/// 测试连的 Codex：钉住的版本（`PinnedAgent.codex`），模型是本用例的假模型（`FakeModel`，Responses），零网络、不用任何登录。
let pinnedCodex = PinnedAgent.codex
let codexTestModel = "gpt-5.5"

/// 一张 64×64 的 sRGB 纯色 PNG（1×1 的图、设备色彩空间里的纯红，模型有时说成别的颜色）。
func solidPNG(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
    let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(
        data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(try #require(CGColor(colorSpace: sRGB, components: [red, green, blue, 1])))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

/// 一个临时的 Codex 配置目录，与它配套的 CuePad 钩子 socket 目录与工作目录。起的 codex 与接入用的环境把家目录、各家的配置目录、
/// XDG 目录、CuePad 的资料库与 socket 目录都指到这里，不读写真实的配置与资料库。
/// 模型提供方写在这个目录的 `config.toml` 里（Codex 只认 Responses；项目目录下的提供方配置会被忽略）。
struct CodexHome {
    let root: URL
    let model: FakeModel
    var home: URL { root.appending(path: "codex", directoryHint: .isDirectory) }
    var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }
    var sockets: URL { root.appending(path: "s", directoryHint: .isDirectory) }
    var paths: AgentPaths {
        AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
    }
    var locator: ExecutableLocator { pinnedCodex.locator }
    var environment: [String: String] {
        func path(_ name: String) -> String { root.appending(path: name).path }
        return pinnedCodex.environment(home: root.appending(path: "user"), [
            "XDG_CONFIG_HOME": path("xdg/config"), "XDG_DATA_HOME": path("xdg/data"),
            "XDG_STATE_HOME": path("xdg/state"), "XDG_CACHE_HOME": path("xdg/cache"), "CLAUDE_CONFIG_DIR": path("claude"),
            "OPENCODE_CONFIG_DIR": path("opencode"), "PI_CODING_AGENT_DIR": path("pi"), "CUEPAD_LIBRARY_DIR": path("library"),
            "CODEX_HOME": home.path, "CUEPAD_PI_SOCKET_DIR": sockets.path, Self.keyVariable: "fake",
        ])
    }
    static let keyVariable = "CUEPAD_FAKE_MODEL_KEY"

    init(model: FakeModel) throws {
        try pinnedCodex.require()
        root = try makeTempDirectory()
        self.model = model
        for directory in [home, work, root.appending(path: "user")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// 配置：假模型当提供方，最便宜的思考强度，信任工作目录（没人回答信任提问），关掉更新检查与遥测。
    func signIn(approvals: String = "never") throws {
        let config = """
            model = "\(codexTestModel)"
            model_reasoning_effort = "low"
            approval_policy = "\(approvals)"
            sandbox_mode = "workspace-write"
            check_for_update_on_startup = false

            [projects."\(work.realPath.path)"]
            trust_level = "trusted"

            """
        try Self.write(provider: model, config: config, into: home)
    }

    /// 把假模型写成这个配置目录的提供方（`model_providers` 只认这里，项目目录下同名的会被忽略），并关掉常驻服务的自动更新。
    static func write(provider model: FakeModel, config: String = "", into home: URL) throws {
        let text = """
            model_provider = "fake"
            \(config)
            [analytics]
            enabled = false

            [model_providers.fake]
            name = "fake"
            base_url = "\(model.baseURL)/v1"
            env_key = "\(keyVariable)"
            wire_api = "responses"

            """
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try text.write(to: home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        let daemon = home.appending(path: "app-server-daemon", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        try #"{"autoUpdateEnabled":false}"#.write(to: daemon.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    }

    @concurrent func remove() async {
        model.stop()
        await TestProcesses.stop(under: [root])
        try? FileManager.default.removeItem(at: root)
    }

    func using(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await remove()
            throw error
        }
        await remove()
    }

    @MainActor func hookTrust() async throws -> [(command: String, event: String, trust: String)] {
        try await listedHooks().map { ($0["command"]?.string ?? "", $0["eventName"]?.string ?? "", $0["trustStatus"]?.string ?? "") }
    }

    @MainActor func trustEverything() async throws {
        var state: [String: JSONValue] = [:]
        for entry in try await listedHooks() { state[entry["key"]!.string!] = ["trusted_hash": entry["currentHash"]!] }
        try await withCodex { try await $0.call("config/batchWrite", ["edits": [["keyPath": "hooks.state", "value": .object(state), "mergeStrategy": "upsert"]]]) }
    }

    @MainActor private func listedHooks() async throws -> [JSONValue] {
        var entries: [JSONValue] = []
        try await withCodex { rpc in
            let list = try await rpc.call("hooks/list", ["cwds": [.string(home.path)]])
            entries = list["data"]?.array?.first?["hooks"]?.array ?? []
        }
        return entries
    }

    @MainActor private func withCodex(_ body: (CodexRPC) async throws -> Void) async throws {
        let rpc = try await CodexRPC.launch(pinnedCodex.executable, environment: environment)
        do {
            try await body(rpc)
        } catch {
            await rpc.shutdown()
            throw error
        }
        await rpc.shutdown()
    }
}

@MainActor
func withCodexRig(approvals: String = "never", _ body: (CodexRig) async throws -> Void) async throws {
    let rig = try await CodexRig(approvals: approvals)
    do {
        try await body(rig)
    } catch {
        await rig.stop()
        throw error
    }
    await rig.stop()
}

@MainActor
final class CodexRig {
    let codex: CodexHome
    let hooks: AgentHookServer
    let bridge: PiBridge
    let runtime: CodexRuntime
    let presence: TestPresence
    var model: FakeModel { codex.model }

    init(approvals: String = "never") async throws {
        let codex = try CodexHome(model: try await FakeModel())
        let presence = TestPresence()
        let hooks = AgentHookServer(path: codex.paths.pi.hookSocket)
        let bridge = PiBridge(socketDirectory: codex.sockets)
        let locator = codex.locator
        let runtime = CodexRuntime(bridge: bridge, paths: codex.paths, hooks: hooks, codex: { [locator] in locator.candidates("codex").first }, locate: { [locator] in locator }, presence: presence, timing: noDeadline)
        do {
            try codex.signIn(approvals: approvals)
            try await AgentIntegration(paths: codex.paths, locate: { [codex] in codex.locator }, cuepad: PiProcess.cuepad, timing: noDeadline).install(.codex)
            try hooks.start()
            try bridge.start()
            try runtime.start()
            runtime.follow(.all)  // 装了钩子：同 App 检测出接入了
        } catch {
            await runtime.stop()()
            hooks.stop()
            bridge.stop()
            await codex.remove()
            throw error
        }
        (self.codex, self.hooks, self.bridge, self.runtime, self.presence) = (codex, hooks, bridge, runtime, presence)
    }

    /// 关掉托管的进程；停掉终端测试起的常驻服务等、删掉临时目录（含凭据，`CodexHome.remove`），再删常驻服务在共用的
    /// /tmp/codex-daemon-<uid> 里留下的 socket 与锁文件（控制 socket 是指向那里的符号链接）。
    func stop() async {
        await runtime.stop()()
        hooks.stop()
        bridge.stop()
        let control = codex.home.appending(path: "app-server-control/app-server-control.sock").path
        let shared = try? FileManager.default.destinationOfSymbolicLink(atPath: control)
        await codex.remove()
        for leftover in shared.map({ [$0, $0 + ".lock"] }) ?? [] { try? FileManager.default.removeItem(atPath: leftover) }
    }

    var session: PiSession? { bridge.sessions.first { $0.agent == .codex } }

    func transcript(_ session: PiSession) throws -> PiHistoryUpdate {
        try PiHistory.index(file: try #require(session.sessionFile), agent: .codex, from: nil, files: scratchFiles)
    }

    func replies(_ session: PiSession) -> [String] {
        ((try? transcript(session))?.messages ?? []).filter { $0.role == .known(.pi) }.map(\.text)
    }

    func draftLanded(_ id: PiSession.ID) -> Bool {
        guard let draft = bridge.slots.first(where: { $0.id == id })?.draft else { return true }
        let session = bridge.session(id: id)
        let newest = session.flatMap { try? transcript($0) }?.messages.last { $0.role == .known(.pi) }?.at
        return draft.landed(newestReply: newest)
    }
}

@MainActor
final class TestPresence: UserPresence {
    var isPresent = false {
        didSet {
            guard isPresent else { return }
            for waiter in waiters { waiter.resume() }
            waiters = []
        }
    }
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func untilPresent() async {
        guard !isPresent else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// 终端里的 Codex：`script` 给它一个带控制终端的伪终端，像人一样往里打字。它首次运行时拉起常驻服务（会话由常驻服务承载）。
final class CodexTerminal: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let screen = Mutex(Data())

    init(_ codex: CodexHome, arguments: [String] = []) throws {
        process.executableURL = URL(filePath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", "stty cols 140 rows 45; exec \"$0\" \"$@\"", pinnedCodex.executable.path] + arguments
        process.environment = codex.environment.merging(["TERM": "xterm-256color"]) { $1 }
        process.currentDirectoryURL = codex.work
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let handle = output.fileHandleForReading, reply = input.fileHandleForWriting
        Thread.detachNewThread { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(handle.fileDescriptor, &buffer, buffer.count)
                if n <= 0 { break }
                let chunk = Data(buffer[0..<n])
                self?.screen.withLock { $0.append(chunk) }
                // 终端界面启动时问光标位置，要有回答才往下走
                if chunk.range(of: Data("\u{1b}[6n".utf8)) != nil { try? reply.write(contentsOf: Data("\u{1b}[1;1R".utf8)) }
            }
        }
    }

    func printed(_ text: String, since offset: Int = 0) -> Bool {
        screen.withLock { $0.range(of: Data(text.utf8), in: min(offset, $0.count)..<$0.count) != nil }
    }

    var printedCount: Int { screen.withLock { $0.count } }

    func press(_ key: String) throws { try input.fileHandleForWriting.write(contentsOf: Data(key.utf8)) }

    /// 粘贴一段话（括号粘贴，界面不会把紧跟着的回车当成粘贴里的换行）再回车。
    func type(_ text: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data("\u{1b}[200~\(text)\u{1b}[201~".utf8))
        try input.fileHandleForWriting.write(contentsOf: Data("\r".utf8))
    }

    func stop() {
        var children = [pid_t](repeating: 0, count: 16)
        let count = proc_listchildpids(process.processIdentifier, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        for child in children.prefix(Int(max(count, 0))) where child > 0 { kill(child, SIGTERM) }
        if process.isRunning { process.terminate() }
    }
}
#endif
