#if os(macOS)
import CueStore
import Darwin
import Foundation

/// 需要 Agent 等答复的事件（权限确认、提问）留着它、稍后 `reply`，其余当场 `finish`；钩子进程先走了（用户在终端里答了，Agent 收回了这次调用）时 `onClose` 被调用一次。
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

    public func reply(_ output: Data) {
        guard !done else { return }
        done = true
        connection.write(output, thenClose: true)
    }

    public func finish() {
        guard !done else { return }
        done = true
        connection.close()
    }

    fileprivate func peerClosed() {
        guard !done else { return }
        done = true
        connection.close()
        onClose?()
    }
}

@MainActor
public final class AgentHookServer {
    private let path: URL
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private(set) var handlers: [AgentKind: @MainActor (AgentHookCall) -> Void] = [:]
    private var open: [ObjectIdentifier: PiSocketConnection] = [:]

    public init(path: URL = PiPaths().hookSocket) {
        self.path = path
    }

    public func handle(_ agent: AgentKind, _ handler: @escaping @MainActor (AgentHookCall) -> Void) {
        handlers[agent] = handler
    }

    /// 所在目录要先经 `PiSocketDirectory.prepare` 建好、校验过。
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
