#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 真实 Pi（`~/.local/bin/pi`，RPC 模式）的测试驱动。
/// 所有状态落在临时 agent 目录（`PI_CODING_AGENT_DIR`），绝不碰真实 ~/.pi；模型是假模型扩展，零网络。
let realPiURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pi")
let realPiAvailable = FileManager.default.isExecutableFile(atPath: realPiURL.path)

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

/// 本机装的 FireCode（用户的 Pi 扩展）源码；只读，测试里软链进临时 agent 目录。
let firecodeSource = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent/extensions/firecode/source").resolvingSymlinksInPath()
let firecodeAvailable = FileManager.default.fileExists(atPath: firecodeSource.appending(path: "index.ts").path)

struct PiEvent: @unchecked Sendable {
    let json: [String: Any]
    subscript(key: String) -> Any? { json[key] }
}

final class PiProcess: @unchecked Sendable {
    let root: URL
    let paths: PiPaths
    let cwd: URL
    private let process = Process()
    private let stdin = Pipe()
    private let lock = NSLock()
    private var _events: [PiEvent] = []
    private var pending = Data()
    private let errPipe = Pipe()
    private var _stderr = Data()
    /// Pi 的 stderr（诊断用）
    var stderr: String { lock.withLock { String(decoding: _stderr, as: UTF8.self) } }

    var pid: Int32 { process.processIdentifier }
    var events: [PiEvent] { lock.withLock { _events } }

    /// - Parameter installBridge: 先用安装器把桥扩展装进临时 agent 目录，让 Pi 按自己的发现规则加载。
    /// - Parameter oneShotPrompt: 非 nil 时以 print 模式跑这条 prompt 然后退出（否则 RPC 常驻）。
    /// - Parameter firecode: 把本机 FireCode 与测试配置装进临时 agent 目录。它的子代理是进程内子会话，只加载 agent 目录里的扩展、
    ///   只认 `models.json` 里的模型，所以假模型也改为装进 agent 目录，并在 `models.json` 里登记。
    init(installBridge: Bool = true, socketDirectory: URL? = nil, extraExtensions: [String] = ["ui-confirm.ts"],
         oneShotPrompt: String? = nil, firecode: Bool = false, env: [String: String] = [:]) async throws {
        root = try makeTempDirectory()
        cwd = root.appending(path: "work")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        paths = PiPaths(agentDirectory: root.appending(path: "agent"), socketDirectory: socketDirectory ?? root.appending(path: "s"))
        if installBridge {
            let installer = PiExtensionInstaller(paths: paths, locator: PiExecutableLocator(searchDirectories: [realPiURL.deletingLastPathComponent()]))
            try await installer.install()
        }

        if firecode { try Self.installFirecode(into: paths.agentDirectory) }

        var args = (oneShotPrompt.map { ["-p", $0] } ?? ["--mode", "rpc"]) + ["--offline", "--no-context-files", "--no-skills", "--no-prompt-templates", "--no-themes",
                    "--model", "fake/echo", "--thinking", "off"]
        if !firecode { args += ["-e", fixtures.appending(path: "fake-model.ts").path] }
        for e in extraExtensions { args += ["-e", fixtures.appending(path: e).path] }

        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("HERDR") && !$0.key.hasPrefix("TMUX") }
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
        Self.drain(errPipe.fileHandleForReading) { [weak self] data in self?.lock.withLock { self?._stderr.append(data) } }
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

    func stop() {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
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
        lock.withLock {
            pending.append(data)
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending = Data(pending[pending.index(after: nl)...])
                if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { _events.append(PiEvent(json: json)) }
            }
        }
    }

    func send(_ command: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: command)
        data.append(0x0A)
        try stdin.fileHandleForWriting.write(contentsOf: data)
    }

    func prompt(_ text: String) throws { try send(["type": "prompt", "message": text]) }

    func waitUntilExit() async {
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func kill(_ signal: Int32) { Darwin.kill(process.processIdentifier, signal) }

    /// 等到某条 Pi 事件（stdout 上的 JSON 行）出现
    func waitForEvent(_ what: String, _ match: @escaping @Sendable (PiEvent) -> Bool) async throws -> PiEvent {
        var found: PiEvent?
        try await eventually(what, timeout: .seconds(20)) {
            found = self.events.first(where: match)
            return found != nil
        }
        return found!
    }
}

// 1×1 红色 PNG
let tinyPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
#endif
