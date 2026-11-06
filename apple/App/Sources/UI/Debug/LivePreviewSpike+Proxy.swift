#if os(iOS) && DEBUG
import Foundation
import Network

/// 手机回环上的入口：HTTP CONNECT 代理、SOCKS5 代理，或原样转发（回环映射）。每条进来的连接对应一条到通道端点的新连接。
nonisolated final class LPProxyServer: @unchecked Sendable {
    enum Kind: String { case connect, socks, raw }
    private let kind: Kind
    private let channels: [UInt16: NWEndpoint]
    private let queue = DispatchQueue(label: "lp.proxy")
    private var listener: NWListener?
    private var serial = 0
    private var ready: CheckedContinuation<UInt16, Never>?

    init(kind: Kind, channels: [UInt16: NWEndpoint]) {
        self.kind = kind
        self.channels = channels
    }

    /// 代理收到的目标往哪接：localhost 的授权端口 → 通道；localhost 的别的端口 → 拒绝（nil）；其余主机 → 手机自己的网络。
    private func route(host: String, port: Int) -> NWEndpoint? {
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())
        if !loopback { return .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!) }
        return channels[UInt16(port)]
    }

    func start(port: UInt16 = 0) async -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        let listener = try! NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return await withCheckedContinuation { continuation in
            ready = continuation
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    LPLog.line("listener[\(self.kind)] ready port=\(listener.port!.rawValue)")
                    self.ready?.resume(returning: listener.port!.rawValue)
                    self.ready = nil
                case .failed(let error):
                    LPLog.line("listener[\(self.kind)] failed \(error)")
                    self.ready?.resume(returning: 0)
                    self.ready = nil
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener?.cancel() }

    private func accept(_ inbound: NWConnection) {
        serial += 1
        let id = "\(kind)#\(serial)"
        inbound.start(queue: queue)
        switch kind {
        case .raw:
            LPLog.line("conn \(id) accepted")
            splice(id: id, inbound: inbound, head: Data(), to: channels.first!.value)
        case .connect:
            readHeader(inbound, buffer: Data()) { header, rest in
                let firstLine = String(decoding: header.prefix { $0 != 13 }, as: UTF8.self)
                LPLog.line("conn \(id) request \"\(firstLine)\"")
                let target = firstLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                guard firstLine.hasPrefix("CONNECT "), let colon = target.lastIndex(of: ":"), let port = Int(target[target.index(after: colon)...]) else {
                    LPLog.line("conn \(id) not CONNECT, closing")
                    inbound.cancel()
                    return
                }
                guard let endpoint = self.route(host: String(target[..<colon]), port: port) else {
                    LPLog.line("conn \(id) refused \(target)")
                    inbound.send(content: Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                    return
                }
                inbound.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .idempotent)
                self.splice(id: id, inbound: inbound, head: rest, to: endpoint)
            }
        case .socks:
            socksHandshake(id: id, inbound)
        }
    }

    private func readHeader(_ connection: NWConnection, buffer: Data, done: @escaping @Sendable (Data, Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                done(buffer.subdata(in: buffer.startIndex..<range.upperBound), buffer.subdata(in: range.upperBound..<buffer.endIndex))
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.readHeader(connection, buffer: buffer, done: done)
            }
        }
    }

    private func readExactly(_ connection: NWConnection, _ count: Int, done: @escaping @Sendable (Data) -> Void) {
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            guard let data, data.count == count, error == nil else { connection.cancel(); return }
            done(data)
        }
    }

    private func socksHandshake(id: String, _ inbound: NWConnection) {
        readExactly(inbound, 2) { greeting in
            self.readExactly(inbound, Int(greeting[greeting.startIndex + 1])) { _ in
                inbound.send(content: Data([5, 0]), completion: .idempotent)
                self.readExactly(inbound, 4) { request in
                    let atyp = request[request.startIndex + 3]
                    let finish: @Sendable (String) -> Void = { address in
                        self.readExactly(inbound, 2) { portBytes in
                            let port = Int(portBytes[portBytes.startIndex]) << 8 | Int(portBytes[portBytes.startIndex + 1])
                            LPLog.line("conn \(id) socks-connect \(address):\(port)")
                            guard let endpoint = self.route(host: address, port: port) else {
                                LPLog.line("conn \(id) refused \(address):\(port)")
                                inbound.send(content: Data([5, 2, 0, 1, 0, 0, 0, 0, 0, 0]), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                                return
                            }
                            inbound.send(content: Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .idempotent)
                            self.splice(id: id, inbound: inbound, head: Data(), to: endpoint)
                        }
                    }
                    switch atyp {
                    case 1: self.readExactly(inbound, 4) { finish($0.map(String.init).joined(separator: ".")) }
                    case 4: self.readExactly(inbound, 16) { finish($0.map { String(format: "%02x", $0) }.joined()) }
                    default:
                        self.readExactly(inbound, 1) { length in
                            self.readExactly(inbound, Int(length[length.startIndex])) { finish(String(decoding: $0, as: UTF8.self)) }
                        }
                    }
                }
            }
        }
    }

    private func splice(id: String, inbound: NWConnection, head: Data, to endpoint: NWEndpoint) {
        let outbound = NWConnection(to: endpoint, using: .tcp)
        outbound.stateUpdateHandler = { state in
            if case .failed(let error) = state { LPLog.line("conn \(id) channel-failed \(error)"); inbound.cancel() }
        }
        outbound.start(queue: queue)
        if !head.isEmpty { outbound.send(content: head, completion: .idempotent) }
        pump(id: id, from: inbound, to: outbound, label: "up")
        pump(id: id, from: outbound, to: inbound, label: "down")
    }

    private func pump(id: String, from: NWConnection, to: NWConnection, label: String, total: Int = 0) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            var total = total
            if let data, !data.isEmpty {
                total += data.count
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if complete || error != nil {
                LPLog.line("conn \(id) \(label)-closed bytes=\(total)\(error.map { " error=\($0)" } ?? "")")
                to.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
                return
            }
            self.pump(id: id, from: from, to: to, label: label, total: total)
        }
    }
}
#endif
