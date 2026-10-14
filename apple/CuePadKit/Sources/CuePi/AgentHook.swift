#if os(macOS)
import CueStore
import Darwin
import Foundation

/// CuePad 这一端：一次钩子调用。适配读 `envelope`，需要 Agent 等答复的事件（权限确认、提问）留着它、稍后 `reply`；
/// 其余当场 `finish`。钩子进程先走了（用户在终端里答了，Agent 收回了这次调用）时 `onClose` 被调用一次。
@MainActor
public final class AgentHookCall {
    public let envelope: AgentHookEnvelope
    private let connection: PiSocketConnection
    private var done = false
    public var onClose: (@MainActor () -> Void)?

    init(envelope: AgentHookEnvelope, connection: PiSocketConnection) {
        self.envelope = envelope
        self.connection = connection
    }

    /// 回给 Agent 的输出（钩子写到标准输出），并结束这次调用。
    public func reply(_ output: Data) {
        guard !done else { return }
        done = true
        connection.write(output, thenClose: true)
    }

    /// 不给输出，Agent 照常往下走。
    public func finish() {
        guard !done else { return }
        done = true
        connection.close()
    }

    public var isFinished: Bool { done }

    fileprivate func peerClosed() {
        guard !done else { return }
        done = true
        connection.close()
        onClose?()
    }
}

/// 钩子 socket 的监听端：收下每次调用，按 Agent 交给它的适配。没有适配认领的直接结束（Agent 照常往下走）。
@MainActor
public final class AgentHookServer {
    private let path: URL
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private var handlers: [AgentKind: @MainActor (AgentHookCall) -> Void] = [:]
    /// 接进来还没结束的连接：停的时候一并关掉（挂着的钩子随即放行）
    private var open: [ObjectIdentifier: PiSocketConnection] = [:]

    public init(path: URL = PiPaths().hookSocket) {
        self.path = path
    }

    public func handle(_ agent: AgentKind, _ handler: @escaping @MainActor (AgentHookCall) -> Void) {
        handlers[agent] = handler
    }

    /// 开始监听（所在目录由 `PiSocketDirectory.prepare` 建好、校验过）。上次没删掉的 socket 文件先删。
    public func start() throws {
        guard listener < 0 else { return }
        try PiSocketDirectory.prepare(path.deletingLastPathComponent())
        let fd: Int32
        do { fd = try UnixSocket.listen(path.path) } catch .pathTooLong { throw PiBridgeError.socketDirectoryTooLong }
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 { unlink(path.path) }
        listener = -1
        for connection in open.values { connection.close() }
        open = [:]
    }

    private func acceptAll() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            guard let connection = try? PiSocketConnection(peer: fd) else { continue }
            Task { await serve(connection) }
        }
    }

    private func serve(_ connection: PiSocketConnection) async {
        open[ObjectIdentifier(connection)] = connection
        defer { open[ObjectIdentifier(connection)] = nil }
        var call: AgentHookCall?
        for await line in connection.lines {
            guard call == nil else { continue }
            guard let envelope = try? JSONDecoder().decode(AgentHookEnvelope.self, from: line), let handler = handlers[envelope.agent] else {
                connection.close()
                return
            }
            let received = AgentHookCall(envelope: envelope, connection: connection)
            call = received
            handler(received)
        }
        call?.peerClosed()
    }
}
#endif
