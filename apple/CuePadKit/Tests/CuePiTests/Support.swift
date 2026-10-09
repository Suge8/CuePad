#if os(macOS)
import Foundation
import Testing
@testable import CuePi

// MARK: - 临时目录 / 条件等待

/// 本进程所有临时目录的根（进程退出时整体删除）。socket 路径有 104 字节上限，所以路径要短：`/tmp/cpt-XXXXXX/N`。
private let temporaryRoot: URL = {
    let root = URL(filePath: "/tmp/cpt-\(String(UUID().uuidString.prefix(6)))", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    atexit { try? FileManager.default.removeItem(atPath: temporaryRootPath) }
    temporaryRootPath = root.path
    return root
}()
nonisolated(unsafe) private var temporaryRootPath = ""
private let temporaryCounter = LockedCounter()

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

func makeTempDirectory() throws -> URL {
    let dir = temporaryRoot.appending(path: String(temporaryCounter.next()), directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return dir
}

func makeSocketDirectory() throws -> URL {
    try makeTempDirectory()
}

struct TimedOut: Error, CustomStringConvertible {
    var description: String
}

/// 条件等待：状态由 FSEvents/socket 异步推进，没有更细的完成信号可订阅时用它，禁止固定 sleep。
func eventually(
    _ what: String, timeout: Duration = .seconds(10),
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(15))
    }
    throw TimedOut(description: "timed out waiting for: \(what)")
}

/// 一个从 socket 目录里消失的文件。
func fileGone(_ url: URL) -> Bool { !FileManager.default.fileExists(atPath: url.path) }

/// 已经退出的进程 pid（用于"残留 socket 的属主已死"）。
func deadPid() throws -> Int32 {
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    return p.processIdentifier
}

/// 会话文件此刻的摘要（对话的投影，见 `PiHistory`）；文件还没落盘时为 nil。
func recap(of session: PiSession?) -> PiTranscriptRecap? {
    session?.sessionFile.flatMap { try? PiHistory.index(file: $0, from: nil).recap }
}

/// 订阅 `changes()` 并记录，供测试断言事件顺序。
@MainActor
final class ChangeLog {
    private(set) var changes: [PiSessionChange] = []
    private var task: Task<Void, Never>?

    init(_ bridge: PiBridge) {
        let stream = bridge.changes()
        task = Task { [weak self] in
            for await change in stream { self?.changes.append(change) }
        }
    }

    deinit { task?.cancel() }

    var ended: [(PiSession, PiSessionEndReason)] {
        changes.compactMap { if case .ended(let s, let r) = $0 { (s, r) } else { nil } }
    }

    var states: [PiAgentState] {
        changes.compactMap { if case .stateChanged(let s, _) = $0 { s.state } else { nil } }
    }
}

// MARK: - 假扩展：说桥协议的 socket 服务端

/// 扮演 Pi 里的桥扩展，让客户端测试不依赖 Pi。字节协议见 CuePi 的 README 与 `PiWire`。
final class FakeExtension: @unchecked Sendable {
    /// 线上的模型对象（`provider`、`id`、`name`、支持的思考强度 `thinking`）
    struct WireModel: Sendable {
        var provider = "test"
        var id: String
        var name = "Test"
        var thinking: [String] = ["off"]
        var json: [String: Any] { ["provider": provider, "id": id, "name": name, "thinking": thinking] }
    }

    struct WireCommand: Sendable {
        var name: String
        var description: String?
        var source = "extension"
        var hint: String?
        var json: [String: Any] {
            ["name": name, "description": description ?? NSNull(), "source": source, "hint": hint ?? NSNull()]
        }
    }

    struct Options: Sendable {
        var protocolVersion = PiWire.protocolVersion
        var extensionVersion = 1
        var cwd = "/work/project"
        var mode = "tui"
        var model: WireModel? = WireModel(id: "test-model")
        var thinking: String? = "off"
        var models: [WireModel] = []
        /// 上下文：已用 token（nil 为未知）与窗口；nil 表示没有模型
        var context: (tokens: Int?, window: Int)?
        var commands: [WireCommand] = []
        var sessionFile: String? = "/work/session.jsonl"
        var tty: String? = "ttys009"
        var socketMode: mode_t = 0o600
        var env: [String: String] = ["TERM_PROGRAM": "ghostty", "__CFBundleIdentifier": "com.mitchellh.ghostty",
                                     "TMUX_PANE": "%3", "TMUX": "/private/tmp/tmux-501/default,123,0"]
    }

    let sessionID: String
    let pid: Int32
    let socketURL: URL
    private let options: Options
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var connections: [Connection] = []
    private var _commands: [(connection: Int, json: [String: Any])] = []
    private var currentState: [String: Any] = ["kind": "idle"]
    private let queue = DispatchQueue(label: "fake-extension")
    /// 对每条命令回一个 ack 体（不含 t/id）；nil 表示不回。
    var onCommand: @Sendable (_ connection: Int, _ command: [String: Any]) -> [String: Any]? = { _, _ in ["ok": true, "delivered": "immediate"] }

    private final class Connection: @unchecked Sendable {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        init(fd: Int32) { self.fd = fd }
    }

    init(directory: URL, sessionID: String = UUID().uuidString.lowercased(), pid: Int32 = getpid(), options: Options = Options()) {
        self.sessionID = sessionID
        self.pid = pid
        self.options = options
        self.socketURL = directory.appending(path: "\(sessionID).\(pid).sock")
    }

    var id: String { "\(sessionID).\(pid)" }

    var commands: [(connection: Int, json: [String: Any])] { lock.withLock { _commands } }
    var connectionCount: Int { lock.withLock { connections.count } }

    func start() throws {
        try? FileManager.default.removeItem(at: socketURL)
        let fd = try Self.boundSocket(at: socketURL)
        guard listen(fd, 8) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        // 与真实扩展一致：bind 之后 chmod（FSEvents 不报告仅 bind 的 socket 创建）
        chmod(socketURL.path, options.socketMode)
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    /// 只 bind 不 listen 后关闭：留下一个无人监听的 socket 文件（进程被强杀后的残留）。
    static func makeStaleSocket(at url: URL) throws {
        let fd = try boundSocket(at: url)
        chmod(url.path, 0o600) // 真实扩展总会 chmod，残留的也是 0600
        Darwin.close(fd)
    }

    private static func boundSocket(at url: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: url.path.utf8) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { Darwin.close(fd); throw POSIXError(.init(rawValue: errno)!) }
        return fd
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        let conn = Connection(fd: fd)
        let index = lock.withLock { connections.append(conn); return connections.count - 1 }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self, weak conn] in
            guard let self, let conn else { return }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { conn.source?.cancel(); return }
            conn.buffer.append(contentsOf: chunk[0..<n])
            while let nl = conn.buffer.firstIndex(of: 0x0A) {
                let line = conn.buffer[conn.buffer.startIndex..<nl]
                conn.buffer = Data(conn.buffer[conn.buffer.index(after: nl)...])
                self.handle(line: Data(line), from: index)
            }
        }
        conn.source = src
        src.resume()
        write(hello(), to: conn)
    }

    private func handle(line: Data, from index: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        lock.withLock { _commands.append((index, json)) }
        guard let id = json["id"] as? String, var ack = onCommand(index, json) else { return }
        ack["t"] = "ack"
        ack["id"] = id
        if let conn = lock.withLock({ connections[safe: index] }) { write(ack, to: conn) }
    }

    private func hello() -> [String: Any] {
        var msg: [String: Any] = [
            "t": "hello", "protocol": options.protocolVersion, "extensionVersion": options.extensionVersion,
            "sessionId": sessionID, "pid": Int(pid), "cwd": options.cwd, "mode": options.mode,
            "term": options.env,
            "state": lock.withLock { currentState }.merging(["since": Self.nowMillis]) { a, _ in a },
        ]
        msg["sessionFile"] = options.sessionFile ?? NSNull()
        msg["model"] = options.model?.json ?? NSNull()
        msg["thinking"] = options.thinking ?? NSNull()
        msg["models"] = options.models.map(\.json)
        msg["context"] = Self.contextJSON(options.context)
        msg["commands"] = options.commands.map(\.json)
        msg["tty"] = options.tty ?? NSNull()
        return msg
    }

    private static func contextJSON(_ context: (tokens: Int?, window: Int)?) -> Any {
        guard let context else { return NSNull() }
        return ["tokens": context.tokens.map { $0 as Any } ?? NSNull(), "window": context.window] as [String: Any]
    }

    static var nowMillis: Int { Int(Date().timeIntervalSince1970 * 1000) }

    private func write(_ object: [String: Any], to conn: Connection) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = Darwin.write(conn.fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    private func broadcast(_ object: [String: Any]) {
        for conn in lock.withLock({ connections }) { write(object, to: conn) }
    }

    /// 发 `info`：整条替换（与真扩展一样总是带全部字段）。
    func setModel(_ model: WireModel?, thinking: String?, models: [WireModel]) {
        broadcast(["t": "info", "model": model?.json ?? NSNull(), "thinking": thinking ?? NSNull(), "models": models.map(\.json)])
    }

    /// 发 `info`：上下文余量与命令清单（整条替换）。
    func setUsage(context: (tokens: Int?, window: Int)?, commands: [WireCommand]) {
        broadcast([
            "t": "info", "context": Self.contextJSON(context),
            "commands": commands.map(\.json),
        ])
    }

    /// 扩展代工具调用发来的"发到手机预览"请求（`show`）；客户端的回复（`shown`）出现在 `commands` 里。
    func requestShow(id: String, path: String, title: String?) {
        broadcast(["t": "show", "id": id, "path": path, "title": title ?? NSNull()])
    }

    /// 客户端对 `show` 的回复（按请求 id）。
    func shown(_ id: String) -> [String: Any]? {
        commands.map(\.json).first { $0["t"] as? String == "shown" && $0["id"] as? String == id }
    }

    /// 发状态切换（`kind` 等字段按协议；`since` 自动补）。
    func setState(_ state: [String: Any]) {
        var s = state
        s["since"] = Self.nowMillis
        lock.withLock { currentState = s }
        broadcast(["t": "state", "state": s])
    }

    /// 发 bye 后关闭全部连接并删除 socket 文件（扩展正常退出）。
    func close(bye reason: String) {
        broadcast(["t": "bye", "reason": reason])
        crash()
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// 不告别直接断开并留下 socket 文件（等同 kill -9）。幂等：fd 是进程全局的，重复 close 会误关别的测试刚复用的描述符。
    func crash() {
        let (listener, open): (Int32, [Connection]) = lock.withLock {
            defer { listenFD = -1; connections = [] }
            return (listenFD, connections)
        }
        source?.cancel()
        source = nil
        if listener >= 0 { Darwin.close(listener) }
        for conn in open {
            conn.source?.cancel()
            shutdown(conn.fd, SHUT_RDWR)
            Darwin.close(conn.fd)
        }
    }

    /// 直接写任意一行到所有连接（协议损坏测试）
    func sendRaw(_ line: String) {
        for conn in lock.withLock({ connections }) {
            let data = Array((line + "\n").utf8)
            _ = data.withUnsafeBytes { Darwin.write(conn.fd, $0.baseAddress!, $0.count) }
        }
    }

    deinit { crash() }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
