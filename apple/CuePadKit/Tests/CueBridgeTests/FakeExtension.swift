#if os(macOS)
import Foundation
import Synchronization
@testable import CueBridge

nonisolated final class FakeExtension: @unchecked Sendable {
    struct WireModel: Sendable {
        var provider = "test"
        var id: String
        var name = "Test"
        var thinking: [String] = ["off"]
        var images: Bool?
        var supportsFast = false
        var json: [String: Any] {
            var json: [String: Any] = ["provider": provider, "id": id, "name": name, "thinking": thinking, "supportsFast": supportsFast]
            if let images { json["images"] = images }
            return json
        }
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
        var extensionVersion = PiExtensionBundle.version
        var cwd = "/work/project"
        var model: WireModel? = WireModel(id: "test-model")
        var thinking: String? = "off"
        var models: [WireModel] = []
        var context: (tokens: Int?, window: Int)?
        var commands: [WireCommand] = []
        var sessionFile: String? = "/work/session.jsonl"
        var launchToken: String?
    }

    let sessionID: String
    let pid: Int32
    let socketURL: URL
    private let options: Options
    private struct Shared {
        var listenFD: Int32 = -1
        var connections: [Connection] = []
        var commands: [(connection: Int, line: Data)] = []
        var state = Data(#"{"kind":"idle"}"#.utf8)
        var turnSince: Int?
        var opener: [String: Any]? { openerData.map(FakeExtension.object) }
        var openerData: Data?
    }
    private let shared = Mutex(Shared())
    private var source: DispatchSourceRead?
    private var socketFile: SocketDirectory.FileIdentity?
    private let queue = DispatchQueue(label: "fake-extension")
    var onCommand: @Sendable (_ connection: Int, _ command: [String: Any]) -> [String: Any]? = { _, _ in ["ok": true] }

    /// 与真扩展（Node：写已断开的连接只得到 EPIPE）一样，写不会让进程收到 SIGPIPE；写与关闭互斥、关闭后的写丢掉：
    /// 回 ack 与另一条线程上的告别关闭（`close(bye:)`）会交错，关闭后再写会落到已关掉的连接或被复用的描述符上，
    /// SIGPIPE 会杀掉整个测试宿主（同 `SocketConnection` 的写法）。
    private final class Connection: @unchecked Sendable {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
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

        /// 停止读、断开连接（shutdown，对端当场读到 EOF）。描述符只在读事件源的取消回调里关（`release`）：事件源还挂在 kqueue 上时就关掉，
        /// 号码马上被别的测试新开的 socket 复用，这个事件源随后的注销会把那个描述符的读事件一起删掉，那边就再也收不到数据（桥等不到 hello）。
        func close() {
            closed.withLock { closed in
                guard !closed else { return }
                closed = true
                shutdown(fd, SHUT_RDWR)
            }
            source?.cancel()
        }

        func release() {
            closed.withLock {
                $0 = true
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
        let pending = socketURL.deletingPathExtension().appendingPathExtension("tmp")
        let fd = try Self.boundSocket(at: pending)
        guard listen(fd, 8) == 0, chmod(pending.path, 0o600) == 0, rename(pending.path, socketURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }
        shared.withLock { $0.listenFD = fd }
        socketFile = SocketDirectory.identity(of: socketURL.path)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.accept() }
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        source = src
    }

    static func makeStaleSocket(at url: URL) throws {
        let fd = try boundSocket(at: url)
        chmod(url.path, 0o600)
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
        src.setCancelHandler { conn.release() }
        conn.source = src
        src.resume()
        write(hello(), to: conn)
    }

    private func handle(line: Data, from index: Int) {
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        shared.withLock { $0.commands.append((index, line)) }
        if json["t"] as? String == "send", let delivery = json["deliveryId"] as? String {
            let opener = try! JSONSerialization.data(withJSONObject: ["delivery": delivery, "cue": json["cue"] as? Bool ?? false])
            let state = shared.withLock { shared in
                shared.openerData = opener
                return Self.object(shared.state)
            }
            setState(state)
        }
        guard let id = json["id"] as? String, var ack = onCommand(index, json) else { return }
        ack["t"] = "ack"
        ack["id"] = id
        if let conn = shared.withLock({ $0.connections[safe: index] }) { write(ack, to: conn) }
    }

    private func hello() -> [String: Any] {
        var msg: [String: Any] = [
            "t": "hello", "extensionVersion": options.extensionVersion,
            "sessionId": sessionID, "pid": Int(pid), "cwd": options.cwd,
            "state": Self.object(shared.withLock { $0.state }).merging([
                "since": Self.nowMillis, "turnSince": shared.withLock { $0.turnSince } ?? NSNull(), "opener": shared.withLock { $0.opener } ?? NSNull(),
            ]) { a, _ in a },
        ]
        msg["sessionFile"] = options.sessionFile ?? NSNull()
        msg["model"] = options.model?.json ?? NSNull()
        msg["thinking"] = options.thinking ?? NSNull()
        msg["models"] = options.models.map(\.json)
        msg["context"] = Self.contextJSON(options.context)
        msg["commands"] = options.commands.map(\.json)
        if let token = options.launchToken { msg["launchToken"] = token }
        return msg
    }

    private static func contextJSON(_ context: (tokens: Int?, window: Int)?) -> Any {
        guard let context else { return NSNull() }
        return ["tokens": context.tokens.map { $0 as Any } ?? NSNull(), "window": context.window] as [String: Any]
    }

    static var nowMillis: Int { Int(Date().timeIntervalSince1970 * 1000) }

    fileprivate static func object(_ data: Data) -> [String: Any] {
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

    func sendInfo(_ fields: [String: Any]) {
        broadcast(["t": "info"].merging(fields) { $1 })
    }

    func sendQuota(provider: String, windows: [[String: Any]], complete: Bool, scope: String? = nil, status: String = "observed") {
        broadcast(["t": "quota", "provider": provider, "account": ["kind": "oauth", "scope": scope ?? "test-\(provider)"],
                   "status": status, "windows": windows, "complete": complete])
    }

    func setState(_ state: [String: Any]) {
        var s = state
        if s["since"] == nil { s["since"] = Self.nowMillis }
        let turnSince = shared.withLock { shared -> Int? in
            let running = ["thinking", "tool"]
            let was = Self.object(shared.state)["kind"] as? String ?? ""
            if let kind = s["kind"] as? String, running.contains(kind), !running.contains(was) { shared.turnSince = Self.nowMillis }
            return shared.turnSince
        }
        s["turnSince"] = turnSince ?? NSNull()
        s["opener"] = shared.withLock { $0.opener } ?? NSNull()
        let data = try! JSONSerialization.data(withJSONObject: s)
        shared.withLock { $0.state = data }
        broadcast(["t": "state", "state": s])
    }

    func close(bye reason: String) {
        broadcast(["t": "bye", "reason": reason])
        crash()
        if let socketFile, SocketDirectory.identity(of: socketURL.path) == socketFile { unlink(socketURL.path) }
    }

    func closeAfterReply(bye reason: String) {
        queue.async { [weak self] in self?.close(bye: reason) }
    }

    func crash() {
        let open = shared.withLock {
            defer { $0.listenFD = -1; $0.connections = [] }
            return $0.connections
        }
        source?.cancel()
        source = nil
        for conn in open { conn.close() }
    }

    func sendRaw(_ line: String) {
        for conn in shared.withLock({ $0.connections }) { conn.write(Data((line + "\n").utf8)) }
    }

    deinit { crash() }
}

nonisolated private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
