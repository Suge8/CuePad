import CryptoKit
import CueStore
import Darwin
import Foundation
import Network
import Synchronization

nonisolated enum LiveTunnel {
    static let queue = DispatchQueue(label: "cuepad.live-tunnel")

    static let keyContext = "cuepad-live-tunnel-v1"
    private static let identity = Data("cuepad-live-v1".utf8)

    /// TLS 1.2 + ECDHE-PSK-CHACHA20-POLY1305（0xCCAC，`tls_ciphersuite_t` 里没有它的名字）：Network.framework 的 PSK 只在 1.2 上握得上，
    /// 1.3 与 QUIC 带 PSK 都握手失败（实测 macOS 27.2、iOS 27 模拟器）；这一套带前向保密，密钥日后泄露也解不开录下的流量。
    static func parameters(key: SymmetricKey) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let psk = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let name = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, psk as __DispatchData, name as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: 0xCCAC)!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }

    struct Request: Equatable, Sendable {
        static let version: UInt8 = 1
        let ticket: Data
        let host: String
        let port: UInt16

        var encoded: Data {
            let name = Data(host.utf8.prefix(255))
            return Data([Self.version]) + ticket + Data([UInt8(port >> 8), UInt8(port & 0xff), UInt8(name.count)]) + name
        }

        static func read(from connection: NWConnection) async throws -> Request {
            let head = try await connection.read(1 + 16 + 3)
            guard head[head.startIndex] == version else { throw LiveTunnelError.protocolMismatch }
            let bytes = [UInt8](head)
            let name = bytes[19] == 0 ? Data() : try await connection.read(Int(bytes[19]))
            return Request(ticket: Data(bytes[1..<17]), host: String(decoding: name, as: UTF8.self), port: UInt16(bytes[17]) << 8 | UInt16(bytes[18]))
        }
    }

    enum Answer: UInt8, Sendable {
        case open = 0
        case ticket = 1
        case refused = 2
        case unreachable = 3
    }

    /// 本机接在局域网上的地址：能广播的网卡（Wi-Fi、有线），不要回环、点对点（代理软件与 VPN 的虚拟网卡）与链路本地（169.254、fe80）。
    /// 不按私网段筛：代理软件的虚拟网卡常在 172.16/12 里。
    static func localAddresses() -> [Address] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [Address] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & (IFF_UP | IFF_RUNNING | IFF_BROADCAST) == IFF_UP | IFF_RUNNING | IFF_BROADCAST, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                  let address = entry.pointee.ifa_addr, let mask = entry.pointee.ifa_netmask, let item = Address(address, mask: mask)
            else { continue }
            found.append(item)
        }
        return found
    }

    struct Address: Codable, Equatable, Sendable {
        let host: String
        let prefix: Int

        init(host: String, prefix: Int) {
            self.host = host
            self.prefix = prefix
        }

        fileprivate init?(_ address: UnsafeMutablePointer<sockaddr>, mask: UnsafeMutablePointer<sockaddr>) {
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let raw = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                guard UInt32(bigEndian: raw.s_addr) >> 16 != 0xa9fe else { return nil }
                self.init(host: Self.text(AF_INET, withUnsafeBytes(of: raw) { Array($0) }), prefix: bits.nonzeroBitCount)
            case AF_INET6:
                let raw = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                let bytes = withUnsafeBytes(of: raw) { Array($0) }
                guard !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80) else { return nil }
                let bits = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
                }
                self.init(host: Self.text(AF_INET6, bytes), prefix: bits)
            default: return nil
            }
        }

        static func text(_ family: Int32, _ bytes: [UInt8]) -> String {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            _ = bytes.withUnsafeBytes { inet_ntop(family, $0.baseAddress, &buffer, socklen_t(buffer.count)) }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }

        func shares(_ other: Address) -> Bool {
            guard let mine = Self.bytes(host), let theirs = Self.bytes(other.host), mine.count == theirs.count else { return false }
            var left = min(prefix, other.prefix)
            for (a, b) in zip(mine, theirs) {
                guard left > 0 else { return true }
                let mask: UInt8 = left >= 8 ? 0xff : ~(0xff >> UInt8(left))
                if a & mask != b & mask { return false }
                left -= 8
            }
            return true
        }

        private static func bytes(_ host: String) -> [UInt8]? {
            var v4 = in_addr(), v6 = in6_addr()
            if inet_pton(AF_INET, host, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
            if inet_pton(AF_INET6, host, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
            return nil
        }
    }
}

nonisolated enum LiveTunnelError: Error {
    case protocolMismatch, timedOut, closed
    case answer(LiveTunnel.Answer)
}

// MARK: 对拷

extension LiveTunnel {
    /// 两条连接原样对拷：一边收到的发完再收下一块，背压自然成立。任一边读完或出错就整条关：TLS 上的半关传不到对面（实测），
    /// 网页视图与开发服务也不靠半关。连接握着收发回调、回调握着它，关掉时一起放掉。
    nonisolated final class Splice: @unchecked Sendable {
        private let a: NWConnection
        private let b: NWConnection
        private var done = false

        private let ended: @Sendable (_ bFailed: Bool) -> Void

        init(_ a: NWConnection, _ b: NWConnection, ended: @escaping @Sendable (_ bFailed: Bool) -> Void = { _ in }) {
            self.a = a
            self.b = b
            self.ended = ended
        }

        func start() {
            for connection in [a, b] {
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .failed: self?.finish(failed: connection)
                    case .cancelled: self?.finish()
                    default: break
                    }
                }
            }
            pump(a, b)
            pump(b, a)
        }

        func close() { LiveTunnel.queue.async { self.finish() } }

        private func pump(_ from: NWConnection, _ to: NWConnection) {
            from.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { data, _, complete, error in
                guard !self.done else { return }
                let failed = error == nil ? nil : from
                let ended = complete || failed != nil
                guard let data, !data.isEmpty else { return ended ? self.finish(failed: failed) : self.pump(from, to) }
                to.send(content: data, completion: .contentProcessed { error in
                    if error != nil || ended { self.finish(failed: error == nil ? failed : to) } else { self.pump(from, to) }
                })
            }
        }

        private func finish(failed: NWConnection? = nil) {
            guard !done else { return }
            done = true
            a.cancel()
            b.cancel()
            ended(failed === b)
        }
    }
}

// MARK: Mac：接手机的连接

extension LiveTunnel {
    nonisolated final class Server: Sendable {
        enum Admission: Sendable {
            case open(host: String, port: UInt16)
            case probe
            case ticket
            case refused
        }

        private let listener: NWListener
        private let open = Mutex(Ledger())
        private struct Ledger {
            var splices: [Data: [ObjectIdentifier: (splice: Splice, port: UInt16)]] = [:]
            var tickets: Set<Data>?
        }
        private let admit: @Sendable (Request) async -> Admission

        init(key: SymmetricKey, admit: @escaping @Sendable (Request) async -> Admission) throws {
            listener = try NWListener(using: LiveTunnel.parameters(key: key))
            self.admit = admit
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                Task { await self.serve(connection) }
            }
        }

        func keep(_ tickets: Set<Data>) {
            let gone = open.withLock { open in
                let gone = open.splices.filter { !tickets.contains($0.key) }.values.flatMap(\.values).map(\.splice)
                open.splices = open.splices.filter { tickets.contains($0.key) }
                open.tickets = tickets
                return gone
            }
            for splice in gone { splice.close() }
        }

        func limit(_ ticket: Data, to ports: Set<UInt16>) {
            let gone = open.withLock { open in
                let gone = open.splices[ticket]?.filter { !ports.contains($0.value.port) } ?? [:]
                for inbound in gone.keys { open.splices[ticket]?[inbound] = nil }
                return gone.values.map(\.splice)
            }
            for splice in gone { splice.close() }
        }

        var connections: Int { open.withLock { $0.splices.values.reduce(0) { $0 + $1.count } } }

        func start() async throws -> UInt16 {
            let listener = listener
            return try await withCheckedThrowingContinuation { ready in
                let once = Mutex(Optional(ready))
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: once.withLock { $0.take() }?.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error): once.withLock { $0.take() }?.resume(throwing: error)
                    case .cancelled: once.withLock { $0.take() }?.resume(throwing: CancellationError())
                    default: break
                    }
                }
                listener.start(queue: LiveTunnel.queue)
            }
        }

        func cancel() {
            listener.cancel()
            keep([])
        }

        private func forget(_ ticket: Data, _ inbound: NWConnection) {
            open.withLock { open in
                open.splices[ticket]?[ObjectIdentifier(inbound)] = nil
                if open.splices[ticket]?.isEmpty == true { open.splices[ticket] = nil }
            }
        }

        private func serve(_ inbound: NWConnection) async {
            do {
                try await inbound.established(within: .seconds(5))
                let request = try await inbound.bounded(.seconds(5)) { try await Request.read(from: inbound) }
                switch await admit(request) {
                case .probe:
                    try await inbound.write(Data([Answer.open.rawValue]))
                    inbound.cancel()
                case .ticket:
                    try? await inbound.write(Data([Answer.ticket.rawValue]))
                    inbound.cancel()
                case .refused:
                    try? await inbound.write(Data([Answer.refused.rawValue]))
                    inbound.cancel()
                case .open(let host, let port):
                    let outbound = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
                    do {
                        try await outbound.established(within: .seconds(3))
                    } catch {
                        outbound.cancel()
                        try? await inbound.write(Data([Answer.unreachable.rawValue]))
                        inbound.cancel()
                        return
                    }
                    let ticket = request.ticket
                    let splice = Splice(inbound, outbound) { [weak self] _ in self?.forget(ticket, inbound) }
                    let kept = open.withLock { open in
                        guard open.tickets?.contains(ticket) ?? true else { return false }
                        open.splices[ticket, default: [:]][ObjectIdentifier(inbound)] = (splice, request.port)
                        return true
                    }
                    guard kept else {
                        outbound.cancel()
                        try? await inbound.write(Data([Answer.ticket.rawValue]))
                        return inbound.cancel()
                    }
                    do { try await inbound.write(Data([Answer.open.rawValue])) } catch { return splice.close() }
                    splice.start()
                }
            } catch {
                inbound.cancel()
            }
        }
    }
}
