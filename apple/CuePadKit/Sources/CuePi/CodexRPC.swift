#if os(macOS)
import Darwin
import Foundation

/// 一条到 Codex app-server 的 JSON-RPC 连接（app-server 协议：没有 `jsonrpc` 字段的 JSON-RPC 2.0）。两种传输：
/// CuePad 自己起的 `codex app-server --listen stdio://`（一行一条 JSON），与常驻服务的控制 socket
/// （`<CODEX_HOME>/app-server-control/app-server-control.sock`，unix socket 上的 WebSocket，一帧一条）。
/// 回应按 id 配给请求；通知交给 `onNotification`，其中回答的逐字增量（`item/agentMessage/delta`）在这里累积成正在说的话交给 `onDraft`，
/// 回答项说完时换成它的全文。
/// 服务端请求（审批、提问）只发给订阅了线程的连接：CuePad 的审批在钩子里答、不开 Plan 模式，所以来了一律回错误，不让对方干等。
@MainActor
final class CodexRPC {
    typealias Object = [String: Any]

    /// 对端进程：自己起的 app-server，或控制 socket 那头的常驻服务
    let pid: Int32
    private let transport: Transport
    private var nextID = 0
    /// 等回应的请求；交回整条回应的原文，在主线程上再取 `result`（`[String: Any]` 不能跨隔离传）
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private var reader: Task<Void, Never>?
    private(set) var isClosed = false
    var onNotification: ((String, Object) -> Void)?
    /// 一个线程正在说的这条回答（`PiDraft`，一个 `agentMessage` 项的正文）变了：随增量更新，这一项说完（`item/completed`）时换成它带的全文
    /// （不发增量时也照样有）；过程中的说明（`phase` 为 commentary）说完、
    /// 下一项开始（转成工具调用、思考等）、下一轮开始、这一轮停下或失败（`turn/completed` 不是 completed）时清掉，正常说完的留着。
    /// 说明说完就清，不等工具那一项开始：两者之间 Codex 先跑 PreToolUse 钩子，状态已切到工具，草稿再留着就和工具那一行叠着；
    /// 说明也不进对话（`CodexHistory` 只收 final_answer），留着换不下。只有订阅了线程的连接（自己起的进程）收得到增量
    var onDraft: ((_ threadID: String, PiDraft?) -> Void)?
    private var drafts: [String: (item: String, draft: PiDraft)] = [:]
    /// 连接断了（进程退出、常驻服务退出）；只调一次
    var onClose: (() -> Void)?

    private init(pid: Int32, transport: Transport, messages: AsyncStream<Data>) {
        self.pid = pid
        self.transport = transport
        reader = Task { [weak self] in
            for await message in messages { self?.receive(message) }
            self?.closed()
        }
    }

    // MARK: 建立

    /// 握手（`initialize`）至多等这么久：对端卡住时不让调用方一直等。
    static let handshakeTimeout: Duration = .seconds(30)

    /// 起一个 `codex app-server --listen stdio://`（`arguments` 接在后面，如 `-c` 覆盖配置）并完成握手；握手失败或超时时停掉这个进程再抛错。
    /// 一条用户输入（`UserInput`）：文字在前（空文字不带）、图片以 data URL 在后。
    static func input(text: String, images: [PiImage]) -> [Object] {
        let text: [Object] = text.isEmpty ? [] : [["type": "text", "text": text, "text_elements": [] as [Any]]]
        return text + images.map { ["type": "image", "url": "data:\($0.mimeType);base64,\($0.data.base64EncodedString())"] }
    }

    static func launch(
        _ executable: URL, arguments: [String] = [], environment: [String: String], directory: URL? = nil
    ) async throws -> CodexRPC {
        let process = try LineProcess(
            executable: executable, arguments: ["app-server", "--listen", "stdio://"] + arguments, directory: directory, environment: environment)
        let rpc = CodexRPC(pid: process.pid, transport: .stdio(process), messages: process.lines)
        try await rpc.handshake()
        return rpc
    }

    /// 自己起的进程（控制 socket 为 nil）：等它退出、取退出原因，或不经主线程停掉它。
    var process: LineProcess? {
        if case .stdio(let process) = transport { process } else { nil }
    }

    /// 停掉对端：自己起的进程直接终止（不等它读到 EOF 收尾，用于它卡住时），控制 socket 断开。
    func terminate() {
        transport.terminate()
    }

    /// 连上常驻服务的控制 socket 并完成握手；socket 不在或连不上抛错。
    static func connect(socket path: String) async throws -> CodexRPC {
        let (fd, pid, leftover) = try await openWebSocket(path)
        let (messages, continuation) = AsyncStream<Data>.makeStream()
        let socket = WebSocket(fd: fd)
        socket.read(after: leftover, into: continuation)
        let rpc = CodexRPC(pid: pid, transport: .socket(socket), messages: messages)
        try await rpc.handshake()
        return rpc
    }

    /// 握手；失败或超过 `handshakeTimeout` 时停掉对端、等它走完再抛错（超时抛 `timedOut`）。
    private func handshake() async throws {
        var timedOut = false
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: Self.handshakeTimeout)) != nil else { return }
            timedOut = true
            self?.terminate()
        }
        defer { timer.cancel() }
        do {
            _ = try await call("initialize", [
                "clientInfo": ["name": "cuepad", "title": "CuePad", "version": "1"],
                "capabilities": ["experimentalApi": true],
            ])
        } catch {
            terminate()
            await reader?.value
            throw timedOut ? CodexRPCError.timedOut : error
        }
        send(["method": "initialized"])
    }

    // MARK: 收发

    /// 发一个请求，等它的回应；服务端回错误时抛 `CodexRPCError.server`，连接先断了抛 `.closed`。
    @discardableResult
    func call(_ method: String, _ params: Object) async throws -> Object {
        guard !isClosed else { throw CodexRPCError.closed }
        nextID += 1
        let id = nextID
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            send(["id": id, "method": method, "params": params])
        }
        let message = (try? JSONSerialization.jsonObject(with: reply)) as? Object ?? [:]
        if let error = message["error"] as? Object {
            throw CodexRPCError.server(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "")
        }
        return message["result"] as? Object ?? [:]
    }

    /// 关掉：自己起的进程关标准输入（app-server 读到 EOF 就收尾退出），控制 socket 直接断开。
    func close() {
        transport.close()
    }

    /// 关掉并等到对端真的走了：自己起的进程关了输入还不走就 SIGTERM，再不走结束它的进程组（`LineProcess.stop`）。
    func shutdown() async {
        if case .stdio(let process) = transport { await process.stop() } else { close() }
        await reader?.value
    }

    private func send(_ message: Object) {
        guard !isClosed, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        transport.write(data)
    }

    private func receive(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? Object else { return }
        let method = message["method"] as? String
        if let id = message["id"], let method {
            send(["id": id, "error": ["code": -32000, "message": "CuePad 不处理 \(method)"]])
        } else if let method {
            let params = message["params"] as? Object ?? [:]
            guard !drafted(method, params) else { return }
            onNotification?(method, params)
        } else if let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: data)
        }
    }

    /// 改正在说的话；增量本身到此为止（不再交给 `onNotification`），返回 true。
    private func drafted(_ method: String, _ params: Object) -> Bool {
        guard let thread = params["threadId"] as? String else { return false }
        switch method {
        case "item/agentMessage/delta":
            guard let item = params["itemId"] as? String, let delta = params["delta"] as? String else { return true }
            let current = drafts[thread].flatMap { $0.item == item ? $0.draft : nil }
            setDraft(thread, item: item, text: (current?.text ?? "") + delta)
            return true
        case "item/started", "turn/started":
            clearDraft(thread)
        case "item/completed":
            guard let item = params["item"] as? Object, item["type"] as? String == "agentMessage" else { break }
            if item["phase"] as? String == "commentary" {
                clearDraft(thread)
            } else if let id = item["id"] as? String, let text = item["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                setDraft(thread, item: id, text: text)
            }
        case "turn/completed" where (params["turn"] as? Object)?["status"] as? String != "completed":
            clearDraft(thread)
        default:
            break
        }
        return false
    }

    /// 一个回答项此刻的全文：同一项接着用它开始出字的时刻，没变不报。
    private func setDraft(_ thread: String, item: String, text: String) {
        let current = drafts[thread].flatMap { $0.item == item ? $0.draft : nil }
        let draft = PiDraft(text: text, since: current?.since ?? .now)
        guard draft != current else { return }
        drafts[thread] = (item, draft)
        onDraft?(thread, draft)
    }

    private func clearDraft(_ thread: String) {
        guard drafts.removeValue(forKey: thread) != nil else { return }
        onDraft?(thread, nil)
    }

    private func closed() {
        guard !isClosed else { return }
        isClosed = true
        transport.close()
        for continuation in pending.values { continuation.resume(throwing: CodexRPCError.closed) }
        pending = [:]
        onClose?()
    }

    // MARK: 传输

    private enum Transport {
        case stdio(LineProcess)
        case socket(WebSocket)

        func write(_ data: Data) {
            switch self {
            case .stdio(let process): process.write(data)
            case .socket(let socket): socket.send(data)
            }
        }

        func close() {
            switch self {
            case .stdio(let process): process.closeInput()
            case .socket(let socket): socket.close()
            }
        }

        func terminate() {
            switch self {
            case .stdio(let process): process.terminate()
            case .socket(let socket): socket.close()
            }
        }
    }

    /// 连上 unix socket、做 WebSocket 握手（本地 socket，同步做完），返回描述符、对端进程与握手后多读到的字节。
    @concurrent private static func openWebSocket(_ path: String) async throws -> (Int32, Int32, Data) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CodexRPCError.unreachable }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); throw CodexRPCError.unreachable }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        var euid: uid_t = 0, egid: gid_t = 0
        guard connected == 0, getpeereid(fd, &euid, &egid) == 0, euid == getuid() else { Darwin.close(fd); throw CodexRPCError.unreachable }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        guard WebSocket.writeAll(fd, Data(request.utf8)) else { Darwin.close(fd); throw CodexRPCError.unreachable }
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let end = Data("\r\n\r\n".utf8)
        while received.range(of: end) == nil {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { Darwin.close(fd); throw CodexRPCError.unreachable }
            received.append(contentsOf: buffer[0..<n])
        }
        let headerEnd = received.range(of: end)!
        let status = String(decoding: received[..<headerEnd.lowerBound], as: UTF8.self)
        guard status.hasPrefix("HTTP/1.1 101") else { Darwin.close(fd); throw CodexRPCError.unreachable }
        return (fd, pid, Data(received[headerEnd.upperBound...]))
    }
}

enum CodexRPCError: Error, Equatable {
    case server(code: Int, message: String)
    case closed
    case unreachable
    /// 对端没有及时握手（已停掉它）
    case timedOut
}

extension CodexRPCError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .server(_, let message): "Codex 拒绝了：\(message)"
        case .closed: "Codex 的 app-server 没有回应就退出了"
        case .unreachable: "连不上 Codex 的常驻服务"
        case .timedOut: "Codex 的 app-server 没有及时回应"
        }
    }
}

/// unix socket 上的 WebSocket 客户端（RFC 6455 的最小子集：文本帧、分片、ping/pong、关闭）。客户端发的帧要加掩码。
/// 描述符的写入与关闭都在 `queue` 上，`open` 只在那里读写：关掉之后排队的写入不会落到被系统复用的描述符上。
private final class WebSocket: @unchecked Sendable {
    let fd: Int32
    private let queue = DispatchQueue(label: "cuepad.codex-ws.write")
    private var open = true

    init(fd: Int32) { self.fd = fd }

    func send(_ payload: Data, opcode: UInt8 = 0x1) {
        var frame = Data([0x80 | opcode])
        let count = payload.count
        if count < 126 {
            frame.append(0x80 | UInt8(count))
        } else if count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(contentsOf: [UInt8(count >> 8), UInt8(count & 0xFF)])
        } else {
            frame.append(0x80 | 127)
            frame.append(contentsOf: (0..<8).reversed().map { UInt8((count >> ($0 * 8)) & 0xFF) })
        }
        let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        let bytes = frame
        queue.async { [self] in
            if open { _ = Self.writeAll(fd, bytes) }
        }
    }

    func close() {
        queue.async { [self] in
            if open { shutdown(fd, SHUT_RDWR) }
        }
    }

    /// 专用线程读帧到连接断开；关闭时才释放描述符（读线程是它最后的使用者）。
    func read(after leftover: Data, into continuation: AsyncStream<Data>.Continuation) {
        Thread.detachNewThread { [self] in
            var pending = leftover
            var message = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            reading: while true {
                while let frame = Self.frame(in: &pending) {
                    switch frame.opcode {
                    case 0x0, 0x1, 0x2:
                        message.append(frame.payload)
                        if frame.final {
                            continuation.yield(message)
                            message = Data()
                        }
                    case 0x8: break reading
                    case 0x9: send(frame.payload, opcode: 0xA)
                    default: break
                    }
                }
                let n = Darwin.read(fd, &buffer, buffer.count)
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
            }
            continuation.finish()
            queue.async { [self] in
                open = false
                Darwin.close(fd)
            }
        }
    }

    /// 从缓冲头上取出一个完整的帧（服务端的帧不带掩码）；不够一帧为 nil。
    private static func frame(in buffer: inout Data) -> (final: Bool, opcode: UInt8, payload: Data)? {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return nil }
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return nil }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return nil }
            length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
            offset = 10
        }
        let masked = bytes[1] & 0x80 != 0
        let maskOffset = offset
        if masked { offset += 4 }
        guard buffer.count >= offset + length else { return nil }
        let start = buffer.startIndex
        var payload = Data(buffer[(start + offset)..<(start + offset + length)])
        if masked {
            let mask = [UInt8](buffer[(start + maskOffset)..<(start + maskOffset + 4)])
            payload = Data(payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        }
        buffer.removeSubrange(start..<(start + offset + length))
        return (bytes[0] & 0x80 != 0, bytes[0] & 0x0F, payload)
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
#endif
