#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import ImageIO
import Network
import Synchronization
import Testing
@testable import CuePi

/// 本机装的 Codex（录制时用）；凭据复制进临时 CODEX_HOME（`copyCodexAuth`），用完删掉。绝不碰真实的 ~/.codex。
let realCodexURL = ExecutableLocator.standard.candidates("codex").first
let realCodexAuth = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/auth.json")
/// 账号里最便宜的模型
let codexTestModel = "gpt-6-luna"

/// 把 ~/.codex/auth.json 复制到 `file`，副本永远不去刷新登录：refresh_token 换成假值、last_refresh 改成现在。
/// 原样复制的话两份都会刷新，refresh token 只能用一次，副本先刷新就把用户的登录挤掉了。access token 过期时副本会失败，不碰用户那份。
func copyCodexAuth(to file: URL) throws {
    var auth = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: realCodexAuth)) as? [String: Any])
    if var tokens = auth["tokens"] as? [String: Any] {
        tokens["refresh_token"] = "cuepad-test-no-refresh"
        auth["tokens"] = tokens
    }
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    auth["last_refresh"] = format.string(from: .now)
    AgentTape.current?.secret(tokens: auth)
    try JSONSerialization.data(withJSONObject: auth).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
}

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
struct CodexHome {
    let root: URL
    var home: URL { root.appending(path: "codex", directoryHint: .isDirectory) }
    var work: URL { root.appending(path: "work", directoryHint: .isDirectory) }
    var sockets: URL { root.appending(path: "s", directoryHint: .isDirectory) }
    var paths: AgentPaths {
        AgentPaths(pi: PiPaths(agentDirectory: root.appending(path: "pi"), socketDirectory: sockets), environment: environment)
    }
    var locator: ExecutableLocator { AgentTape.locator("codex") }
    var environment: [String: String] {
        let isolated = ["CUEPAD_", "HERDR", "TMUX", "XDG_", "CLAUDE_", "OPENCODE_", "CODEX_", "PI_"]
        func path(_ name: String) -> String { root.appending(path: name).path }
        return ProcessInfo.processInfo.environment.filter { key, _ in !isolated.contains { key.hasPrefix($0) } }.merging([
            "HOME": path("user"), "XDG_CONFIG_HOME": path("xdg/config"), "XDG_DATA_HOME": path("xdg/data"),
            "XDG_STATE_HOME": path("xdg/state"), "XDG_CACHE_HOME": path("xdg/cache"), "CLAUDE_CONFIG_DIR": path("claude"),
            "OPENCODE_CONFIG_DIR": path("opencode"), "PI_CODING_AGENT_DIR": path("pi"), "CUEPAD_LIBRARY_DIR": path("library"),
            "CODEX_HOME": home.path, "CUEPAD_PI_SOCKET_DIR": sockets.path,
        ]) { $1 }
    }

    init() throws {
        root = try makeTempDirectory()
        for directory in [home, work, root.appending(path: "user")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        AgentTape.current?.watch(home.appending(path: "sessions"), home.appending(path: "config.toml"), work)
    }

    /// 能跑模型的配置：复制凭据、最便宜的模型、不检查更新、常驻服务不自动升级、工作目录受信任。
    func signIn(approvals: String = "never") throws {
        if AgentTape.current?.mode != .replay { try copyCodexAuth(to: home.appending(path: "auth.json")) }
        let config = """
            model = "\(codexTestModel)"
            model_reasoning_effort = "low"
            approval_policy = "\(approvals)"
            sandbox_mode = "workspace-write"
            check_for_update_on_startup = false

            [projects."\(work.realPath.path)"]
            trust_level = "trusted"

            """
        try config.write(to: home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
        let daemon = home.appending(path: "app-server-daemon", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        try #"{"autoUpdateEnabled":false}"#.write(to: daemon.appending(path: "settings.json"), atomically: true, encoding: .utf8)
    }

    /// 模型改走本机的假提供方（`RejectingProvider`）。
    func use(_ provider: RejectingProvider) throws {
        let config = home.appending(path: "config.toml")
        let text = try String(contentsOf: config, encoding: .utf8)
        try ("model_provider = \"rejecting\"\n" + text + """

            [model_providers.rejecting]
            name = "rejecting"
            base_url = "http://127.0.0.1:\(provider.port)/v1"
            wire_api = "responses"

            """).write(to: config, atomically: true, encoding: .utf8)
    }

    /// 停掉在里面跑的进程（终端界面拉起的常驻服务与它的升级进程、它们起的 git，见 `TestProcesses`），再删掉临时目录（含复制的凭据）。
    @concurrent func remove() async {
        TestProcesses.stop(under: [root])
        try? FileManager.default.removeItem(at: root)
    }

    /// 跑 `body`，不论成败都 `remove`。
    func using(_ body: () async throws -> Void) async throws {
        do {
            try await body()
        } catch {
            await remove()
            throw error
        }
        await remove()
    }

    /// 经 Codex 自己的 app-server 读它此刻看到的钩子（命令 → 信任状态）。
    @MainActor func hookTrust() async throws -> [(command: String, event: String, trust: String)] {
        try await listedHooks().map { ($0["command"]?.string ?? "", $0["eventName"]?.string ?? "", $0["trustStatus"]?.string ?? "") }
    }

    /// 像用户在 Codex 的 /hooks 里点了信任：把 Codex 列出的条目全部信任。
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

    /// 起一个指向这个配置目录的 app-server，用完（失败也一样）等它退出。
    @MainActor private func withCodex(_ body: (CodexRPC) async throws -> Void) async throws {
        let rpc = try await CodexRPC.launch(AgentTape.executable("codex"), environment: environment)
        do {
            try await body(rpc)
        } catch {
            await rpc.shutdown()
            throw error
        }
        await rpc.shutdown()
    }
}

/// 起一整套接入交给 `body`，结束后（失败也一样）停掉它起的进程、删掉临时目录。
@MainActor
func withCodexRig(approvals: String = "never", wrapped: Bool = false, _ body: (CodexRig) async throws -> Void) async throws {
    let rig = try await CodexRig(approvals: approvals, wrapped: wrapped)
    do {
        try await body(rig)
    } catch {
        await rig.stop()
        throw error
    }
    await rig.stop()
}

/// 一整套接入：临时 Codex 配置目录（装好 CuePad 的钩子与技能）、钩子 socket、桥与 Codex 的接入。
@MainActor
final class CodexRig {
    let codex: CodexHome
    let hooks: AgentHookServer
    let bridge: PiBridge
    let runtime: CodexRuntime
    /// 人在不在这台 Mac 前：默认不在（确认交给 CuePad）
    let presence: TestPresence

    /// 钩子命令里的 cuepad。Codex 的信任哈希按命令算，录下的哈希回放时要对得上，所以路径不能带检出位置：
    /// 固定的 /tmp 链接，指向本次构建的 cuepad（录制时真钩子经它跑）。
    static let hookHelper: URL = {
        let link = URL(filePath: "/tmp/cuepad-test-helper/cuepad")
        try! FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? link.checkResourceIsReachable()) != nil || (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try! FileManager.default.removeItem(at: link)
        }
        try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: PiProcess.cuepad)
        return link
    }()

    /// 中途失败时停掉已经起来的、删掉临时目录（含复制的凭据）再抛错。
    /// - Parameter wrapped: CuePad 起的 `codex` 是一层外壳、真 codex 是它的子进程（npm 装的 `codex` 就是 node 外壳），钩子的父进程不是 CuePad 起的那个。
    init(approvals: String = "never", wrapped: Bool = false) async throws {
        let codex = try CodexHome()
        let presence = TestPresence()
        let hooks = AgentHookServer(path: codex.paths.pi.hookSocket)
        let bridge = PiBridge(socketDirectory: codex.sockets)
        var locator = codex.locator
        if wrapped {
            let bin = codex.root.appending(path: "wrapper", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let script = bin.appending(path: "codex")
            try "#!/bin/sh\n'\(AgentTape.executable("codex").path)' \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            locator = ExecutableLocator(searchDirectories: [bin])
        }
        let runtime = CodexRuntime(bridge: bridge, paths: codex.paths, hooks: hooks, codex: { [locator] in locator.candidates("codex").first }, locate: { [locator] in locator }, presence: presence)
        do {
            try codex.signIn(approvals: approvals)
            try await AgentIntegration(paths: codex.paths, locate: { [codex] in codex.locator }, cuepad: Self.hookHelper).install(.codex)
            try hooks.start()
            try bridge.start()
            try runtime.start()
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

    /// 会话文件此刻的对话（你的话里的图片存进临时附件目录）。
    func transcript(_ session: PiSession) throws -> PiHistoryUpdate {
        try PiHistory.index(file: try #require(session.sessionFile), agent: .codex, from: nil, files: scratchFiles)
    }

    func replies(_ session: PiSession) -> [String] {
        ((try? transcript(session))?.messages ?? []).filter { $0.role == .known(.pi) }.map(\.text)
    }

    /// 正在说的话已换下：没有，或会话页认得出它已在对话里（`PiDraft.landed`，对着会话文件里最近一条回答）。
    func draftLanded(_ id: PiSession.ID) -> Bool {
        guard let draft = bridge.slots.first(where: { $0.id == id })?.draft else { return true }
        let session = bridge.session(id: id)
        let newest = session.flatMap { try? transcript($0) }?.messages.last { $0.role == .known(.pi) }?.at
        return draft.landed(newestReply: newest)
    }
}

/// 测试里说了算的人在不在：变成在时叫醒等着的。
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
        process.arguments = ["-q", "/dev/null", "/bin/sh", "-c", "stty cols 140 rows 45; exec \"$0\" \"$@\"", realCodexURL!.path] + arguments
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

    /// 终端从第 `offset` 个字节起输出过的里有没有这段文字。
    func printed(_ text: String, since offset: Int = 0) -> Bool {
        screen.withLock { $0.range(of: Data(text.utf8), in: min(offset, $0.count)..<$0.count) != nil }
    }

    /// 到此刻输出了多少字节（配合 `printed(_:since:)` 只看之后的）。
    var printedCount: Int { screen.withLock { $0.count } }

    /// 按一个键（不当粘贴）。
    func press(_ key: String) throws { try input.fileHandleForWriting.write(contentsOf: Data(key.utf8)) }

    /// 粘贴一段话（括号粘贴，界面不会把紧跟着的回车当成粘贴里的换行）再回车。
    func type(_ text: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data("\u{1b}[200~\(text)\u{1b}[201~".utf8))
        try input.fileHandleForWriting.write(contentsOf: Data("\r".utf8))
    }

    /// 停掉终端里的 codex 与包着它的 `script`（按确切的进程号）。
    func stop() {
        var children = [pid_t](repeating: 0, count: 16)
        let count = proc_listchildpids(process.processIdentifier, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        for child in children.prefix(Int(max(count, 0))) where child > 0 { kill(child, SIGTERM) }
        if process.isRunning { process.terminate() }
    }
}
/// 本机的假模型提供方：每个请求都回 400 和一句固定的原因。
final class RejectingProvider: Sendable {
    static let reason = "bad things happened"
    private let listener: NWListener
    let port: UInt16

    init() async throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            // 请求读一块就够了：不论问什么都拒绝
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { _, _, _, _ in
                let body = #"{"error":{"message":"\#(Self.reason)","type":"invalid_request_error","code":"bad"}}"#
                let reply = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = AsyncStream<UInt16>.makeStream()
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state, let port = listener.port?.rawValue { ready.continuation.yield(port) }
        }
        listener.start(queue: .global())
        var iterator = ready.stream.makeAsyncIterator()
        port = try #require(await iterator.next())
    }

    func stop() { listener.cancel() }
}
#endif
