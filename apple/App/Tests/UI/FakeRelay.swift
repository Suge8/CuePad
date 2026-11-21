#if os(macOS)
import Foundation
import Network
import Synchronization

nonisolated final class FakeRelay: Sendable {
    private struct State {
        var live: [(id: Int, connection: NWConnection)] = []
        var joined = 0
        var rings = 0
        var holding = false
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-relay")
    private let state = Mutex(State())
    let endpoint: URL

    init() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let socket = NWProtocolWebSocket.Options()
        socket.autoReplyPing = true
        parameters.defaultProtocolStack.applicationProtocols.insert(socket, at: 0)
        let listener = try NWListener(using: parameters), queue = queue
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            let once = Mutex(Optional(ready))
            listener.stateUpdateHandler = { update in
                switch update {
                case .ready: once.withLock { $0.take() }?.resume(returning: listener.port!.rawValue)
                case .failed(let error): once.withLock { $0.take() }?.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }
        self.listener = listener
        endpoint = URL(string: "ws://127.0.0.1:\(port)/v1")!
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
    }

    deinit { listener.cancel() }

    var joined: Int { state.withLock { $0.joined } }
    var rings: Int { state.withLock { $0.rings } }

    func drop(_ index: Int, holding: Bool) {
        let dropped = state.withLock { state in
            state.holding = holding
            return state.live.first { $0.id == index }?.connection
        }
        dropped?.cancel()
    }

    func release() { state.withLock { $0.holding = false } }

    private func accept(_ connection: NWConnection) {
        guard !state.withLock({ $0.holding }) else { return connection.cancel() }
        connection.stateUpdateHandler = { [weak self] update in
            switch update {
            case .failed, .cancelled: self?.state.withLock { $0.live.removeAll { $0.connection === connection } }
            default: break
            }
        }
        connection.start(queue: queue)
        send(#"{"t":"challenge","n":"nonce"}"#, to: connection)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return connection.cancel() }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            guard metadata?.opcode == .text else { return receive(on: connection) }  // ping、pong 由协议层自己回
            guard let data,
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let kind = frame["t"] as? String
            else { return connection.cancel() }
            switch kind {
            case "auth":
                state.withLock { state in
                    state.live.append((state.joined, connection))
                    state.joined += 1
                }
                send(#"{"t":"ready"}"#, to: connection)
            case "ring":
                let others = state.withLock { state in
                    state.rings += 1
                    return state.live.map(\.connection).filter { $0 !== connection }
                }
                for other in others { send(#"{"t":"ring"}"#, to: other) }
            default: return connection.cancel()
            }
            receive(on: connection)
        }
    }

    private func send(_ text: String, to connection: NWConnection) {
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true, completion: .idempotent)
    }
}
#endif
