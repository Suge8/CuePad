import Foundation
import Testing
@testable import CuePi

/// 真实 Pi（`~/.local/bin/pi`，RPC 模式）的测试驱动。
/// 所有状态落在临时 agent 目录（`PI_CODING_AGENT_DIR`），绝不碰真实 ~/.pi；模型是假模型扩展，零网络。
let realPiURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/pi")
let realPiAvailable = FileManager.default.isExecutableFile(atPath: realPiURL.path)

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures")

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

    var pid: Int32 { process.processIdentifier }
    var events: [PiEvent] { lock.withLock { _events } }

    /// - Parameter installBridge: 先用安装器把桥扩展装进临时 agent 目录，让 Pi 按自己的发现规则加载。
    init(installBridge: Bool = true, socketDirectory: URL? = nil, extraExtensions: [String] = ["ui-confirm.ts"],
         env: [String: String] = [:]) async throws {
        root = try makeTempDirectory()
        cwd = root.appending(path: "work")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        paths = PiPaths(agentDirectory: root.appending(path: "agent"), socketDirectory: socketDirectory ?? root.appending(path: "s"))
        if installBridge {
            let installer = PiExtensionInstaller(paths: paths, locator: PiExecutableLocator(searchDirectories: [realPiURL.deletingLastPathComponent()]))
            try await installer.install()
        }

        var args = ["--mode", "rpc", "--offline", "--no-context-files", "--no-skills", "--no-prompt-templates", "--no-themes",
                    "--model", "fake/echo", "--thinking", "off", "-e", fixtures.appending(path: "fake-model.ts").path]
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
        process.standardError = Pipe()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.ingest(handle.availableData) }
        try process.run()
    }

    deinit {
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: root)
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
