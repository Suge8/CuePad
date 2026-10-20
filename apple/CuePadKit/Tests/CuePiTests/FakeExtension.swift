#if os(macOS)
import Foundation
import Synchronization
@testable import CuePi

/// 扮演 Pi 里的桥扩展，让客户端测试不依赖 Pi。字节协议见 CuePi 的 README 与 `PiWire`。
/// 连接与收到的命令在 socket 队列上写、测试里读，放在锁里；`onCommand` 这类配置由测试在启动前设好。
/// CuePadKit 的桥测试与 App 测试共用这一份：App 工程不同步这个目录，是直接引用这个文件，改名或挪位置要同时改工程文件。
nonisolated final class FakeExtension: @unchecked Sendable {
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
        /// CuePad 在后台托管的进程（hello 里带 `hosted`）
        var hosted = false
        var env: [String: String] = ["TERM_PROGRAM": "ghostty", "__CFBundleIdentifier": "com.mitchellh.ghostty",
                                     "TMUX_PANE": "%3", "TMUX": "/private/tmp/tmux-501/default,123,0"]
    }

    let sessionID: String
    let pid: Int32
    let socketURL: URL
    private let options: Options
    private struct Shared {
        var listenFD: Int32 = -1
        var connections: [Connection] = []
        /// 收到的命令与此刻的状态存原样的 JSON 字节：字典里是 Any，不能交给锁，读的时候再解。
        var commands: [(connection: Int, line: Data)] = []
        var state = Data(#"{"kind":"idle"}"#.utf8)
        /// 最后一轮开始的时刻（毫秒，扩展的 `turnSince`）
        var turnSince: Int?
    }
    private let shared = Mutex(Shared())
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "fake-extension")
    /// 对每条命令回一个 ack 体（不含 t/id）；nil 表示不回。
    var onCommand: @Sendable (_ connection: Int, _ command: [String: Any]) -> [String: Any]? = { _, _ in ["ok": true] }

    /// 与真扩展（Node：写已断开的连接只得到 EPIPE）一样，写不会让进程收到 SIGPIPE；写与关闭互斥、关闭后的写丢掉：
    /// 回 ack 与另一条线程上的告别关闭（`close(bye:)`）会交错，关闭后再写会落到已关掉的连接或被复用的描述符上，
    /// 曾以 SIGPIPE 杀掉整个测试宿主（同 `PiSocket` 的写法）。
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        /// 已关闭
        private let closed = Mutex(false)

        init(fd: Int32) {
            self.fd = fd
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }

        func write(_ data: Data) {
            closed.withLock { closed in
                guard !closed else { return }
                data.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                        if n <= 0 { return }
                        off += n
                    }
                }
            }
        }

        func close() {
            closed.withLock { closed in
                guard !closed else { return }
                closed = true
                source?.cancel()
                shutdown(fd, SHUT_RDWR)
                Darwin.close(fd)
            }
        }
    }

    init(directory: URL, sessionID: String = UUID().uuidString.lowercased(), pid: Int32 = getpid(), options: Options = Options()) {
        self.sessionID = sessionID
        self.pid = pid
        self.options = options
        self.socketURL = directory.appending(path: "\(sessionID).\(pid).sock")
    }

    var id: String { "\(sessionID).\(pid)" }

    var commands: [(connection: Int, json: [String: Any])] {
        shared.withLock { $0.commands }.map { ($0.connection, Self.object($0.line)) }
    }
    var connectionCount: Int { shared.withLock { $0.connections.count } }

    func start() throws {
        try? FileManager.default.removeItem(at: socketURL)
        // 与真实扩展一致：在临时名上 listen、定好权限，再改名进来
        let pending = socketURL.deletingPathExtension().appendingPathExtension("tmp")
        let fd = try Self.boundSocket(at: pending)
        guard listen(fd, 8) == 0, chmod(pending.path, options.socketMode) == 0, rename(pending.path, socketURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        shared.withLock { $0.listenFD = fd }
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
        let fd = Darwin.accept(shared.withLock { $0.listenFD }, nil, nil)
        guard fd >= 0 else { return }
        let conn = Connection(fd: fd)
        let index = shared.withLock { $0.connections.append(conn); return $0.connections.count - 1 }
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
        shared.withLock { $0.commands.append((index, line)) }
        guard let id = json["id"] as? String, var ack = onCommand(index, json) else { return }
        ack["t"] = "ack"
        ack["id"] = id
        if let conn = shared.withLock({ $0.connections[safe: index] }) { write(ack, to: conn) }
    }

    private func hello() -> [String: Any] {
        var msg: [String: Any] = [
            "t": "hello", "protocol": options.protocolVersion, "extensionVersion": options.extensionVersion,
            "sessionId": sessionID, "pid": Int(pid), "cwd": options.cwd, "mode": options.mode,
            "term": options.env,
            "state": Self.object(shared.withLock { $0.state }).merging(["since": Self.nowMillis, "turnSince": shared.withLock { $0.turnSince } ?? NSNull()]) { a, _ in a },
        ]
        msg["sessionFile"] = options.sessionFile ?? NSNull()
        msg["model"] = options.model?.json ?? NSNull()
        msg["thinking"] = options.thinking ?? NSNull()
        msg["models"] = options.models.map(\.json)
        msg["context"] = Self.contextJSON(options.context)
        msg["commands"] = options.commands.map(\.json)
        msg["tty"] = options.tty ?? NSNull()
        if options.hosted { msg["hosted"] = true }
        return msg
    }

    private static func contextJSON(_ context: (tokens: Int?, window: Int)?) -> Any {
        guard let context else { return NSNull() }
        return ["tokens": context.tokens.map { $0 as Any } ?? NSNull(), "window": context.window] as [String: Any]
    }

    static var nowMillis: Int { Int(Date().timeIntervalSince1970 * 1000) }

    private static func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func write(_ object: [String: Any], to conn: Connection) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        conn.write(data)
    }

    private func broadcast(_ object: [String: Any]) {
        for conn in shared.withLock({ $0.connections }) { write(object, to: conn) }
    }

    /// 发 `info`：只带变了的几项，没带的不变（hello 才带全部）；这里是模型配置那三项。
    func setModel(_ model: WireModel?, thinking: String?, models: [WireModel]) {
        broadcast(["t": "info", "model": model?.json ?? NSNull(), "thinking": thinking ?? NSNull(), "models": models.map(\.json)])
    }

    /// 发 `info`：上下文余量与命令清单。
    func setUsage(context: (tokens: Int?, window: Int)?, commands: [WireCommand]) {
        broadcast([
            "t": "info", "context": Self.contextJSON(context),
            "commands": commands.map(\.json),
        ])
    }

    /// 发只带 `fields` 的 `info`。
    func sendInfo(_ fields: [String: Any]) {
        broadcast(["t": "info"].merging(fields) { $1 })
    }

    /// 发 `quota`：订阅额度的一次观测（`windows` 按线上格式：`seconds`、`used`、`resetsAt` 秒、可选 `model`、`binding`）。
    func sendQuota(provider: String, windows: [[String: Any]], complete: Bool) {
        broadcast(["t": "quota", "provider": provider, "windows": windows, "complete": complete])
    }

    /// 发状态切换（`kind` 等字段按协议；`since` 自动补）。从不在跑进入思考或调工具是开始新的一轮：`turnSince` 记成此刻（同扩展在回合开始时记）。
    func setState(_ state: [String: Any]) {
        var s = state
        s["since"] = Self.nowMillis
        let turnSince = shared.withLock { shared -> Int? in
            let running = ["thinking", "tool"]
            let was = Self.object(shared.state)["kind"] as? String ?? ""
            if let kind = s["kind"] as? String, running.contains(kind), !running.contains(was) { shared.turnSince = Self.nowMillis }
            return shared.turnSince
        }
        s["turnSince"] = turnSince ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: s)
        shared.withLock { $0.state = data }
        broadcast(["t": "state", "state": s])
    }

    /// 发 bye 后关闭全部连接并删除 socket 文件（扩展正常退出）。
    func close(bye reason: String) {
        broadcast(["t": "bye", "reason": reason])
        crash()
        try? FileManager.default.removeItem(at: socketURL)
    }

    /// 回完手上这条命令再告别退出（Pi 收到 end 也是先回 ack 再走）：排在处理命令的同一条队列上，ack 一定先于 bye 写出。
    func closeAfterReply(bye reason: String) {
        queue.async { [weak self] in self?.close(bye: reason) }
    }

    /// 不告别直接断开并留下 socket 文件（等同 kill -9）。幂等：fd 是进程全局的，重复 close 会误关别的测试刚复用的描述符。
    func crash() {
        let (listener, open): (Int32, [Connection]) = shared.withLock {
            defer { $0.listenFD = -1; $0.connections = [] }
            return ($0.listenFD, $0.connections)
        }
        source?.cancel()
        source = nil
        if listener >= 0 { Darwin.close(listener) }
        for conn in open { conn.close() }
    }

    /// 直接写任意一行到所有连接（协议损坏测试）
    func sendRaw(_ line: String) {
        for conn in shared.withLock({ $0.connections }) { conn.write(Data((line + "\n").utf8)) }
    }

    deinit { crash() }
}

nonisolated private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
