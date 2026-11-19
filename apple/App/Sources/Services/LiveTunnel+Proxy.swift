import CryptoKit
import Darwin
import Foundation
import Network
import Synchronization

extension LiveTunnel {
    /// 去 Mac 的路：Mac 答来的入口（`LiveSignal.Door`）里连得上的那个地址（`LiveLink` 探出来），与这张票据。
    nonisolated struct Route: Sendable {
        let key: SymmetricKey
        let ticket: Data
        let mac: NWEndpoint
        /// Mac 在局域网上的地址：页面直接写它们的也走隧道。
        let addresses: Set<String>
    }

    /// 只听回环、带随机口令的 SOCKS5 代理（RFC 1928 + RFC 1929），设给预览那一份网页数据（`LivePreview`）：同机别的应用连得上回环口，没有口令进不来。
    /// 目标是 Mac 本机的（`isMac`）走隧道，别的（字体、CDN）由手机直连。
    nonisolated final class Proxy: Sendable {
        let user = "cuepad"
        let password = UUID().uuidString
        private let listener: NWListener
        private let route = Mutex<Route?>(nil)
        /// 隧道不通了（票据不认、Mac 的口连不上）：`LiveLink` 重新探路。
        let broken: AsyncStream<Answer?>
        private let report: AsyncStream<Answer?>.Continuation

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            (broken, report) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        }

        func start() async throws -> UInt16 {
            let listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                let route = route.withLock { $0 }
                Task { await Self.serve(connection, user: self.user, password: self.password, route: route, report: self.report) }
            }
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

        func use(_ next: Route?) { route.withLock { $0 = next } }

        func cancel() {
            listener.cancel()
            report.finish()
        }

        /// 网页视图的代理配置：代理不通时不绕过它直连（`allowFailover`），页面不会悄悄连到手机自己的 localhost 上。
        func configuration(port: UInt16) -> ProxyConfiguration {
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!))
            proxy.applyCredential(username: user, password: password)
            proxy.allowFailover = false
            return proxy
        }

        /// 本机名、回环地址与 Mac 在局域网上的地址：都是 Mac 那台机器上的。
        static func isMac(_ host: String, addresses: Set<String>) -> Bool {
            let host = host.lowercased()
            if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || addresses.contains(host) { return true }
            var v4 = in_addr()
            return inet_pton(AF_INET, host, &v4) == 1 && UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }

        private static func serve(_ local: NWConnection, user: String, password: String, route: Route?, report: AsyncStream<Answer?>.Continuation) async {
            do {
                try await local.established(within: .seconds(5))
                let (host, port) = try await local.bounded(.seconds(5)) { try await handshake(local, user: user, password: password) }
                let remote: NWConnection
                if isMac(host, addresses: route?.addresses ?? []) {
                    guard let route else { return refuse(local, 3) }  // 网络不可达：还没有去 Mac 的路
                    remote = NWConnection(to: route.mac, using: LiveTunnel.parameters(key: route.key))
                    do {
                        try await remote.established(within: .seconds(4))
                        try await remote.write(Request(ticket: route.ticket, host: host, port: port).encoded)
                        let answer = try await remote.bounded(.seconds(5)) { try await remote.read(1) }.first.flatMap(Answer.init) ?? .refused
                        guard answer == .open else {
                            remote.cancel()
                            if answer == .ticket { report.yield(answer) }
                            return refuse(local, answer == .refused ? 2 : 5)
                        }
                    } catch {
                        remote.cancel()
                        report.yield(nil)
                        return refuse(local, 3)
                    }
                } else {
                    remote = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
                    do {
                        try await remote.established(within: .seconds(15))
                    } catch {
                        remote.cancel()
                        return refuse(local, 4)
                    }
                }
                try await local.write(Data([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]))
                Splice(local, remote).start()
            } catch {
                local.cancel()
            }
        }

        private static func refuse(_ local: NWConnection, _ code: UInt8) {
            local.send(content: Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in local.cancel() })
        }

        /// 问候、认口令、读 CONNECT：返回要连的主机与端口。口令不对回失败并断开。
        private static func handshake(_ local: NWConnection, user: String, password: String) async throws -> (String, UInt16) {
            let hello = try await local.read(2)
            let methods = try await local.read(Int(hello[hello.startIndex + 1]))
            guard hello.first == 5, methods.contains(2) else {
                try? await local.write(Data([5, 0xff]))
                throw LiveTunnelError.protocolMismatch
            }
            try await local.write(Data([5, 2]))
            let version = try await local.read(2)
            let name = try await local.read(Int(version[version.startIndex + 1]))
            let length = try await local.read(1)
            let secret = try await local.read(Int(length[length.startIndex]))
            guard String(decoding: name, as: UTF8.self) == user, String(decoding: secret, as: UTF8.self) == password else {
                try? await local.write(Data([1, 1]))
                throw LiveTunnelError.protocolMismatch
            }
            try await local.write(Data([1, 0]))
            let head = [UInt8](try await local.read(4))
            guard head[0] == 5, head[1] == 1 else { throw LiveTunnelError.protocolMismatch }
            let host: String
            switch head[3] {
            case 1: host = [UInt8](try await local.read(4)).map(String.init).joined(separator: ".")
            case 3: host = String(decoding: try await local.read(Int((try await local.read(1)).first ?? 0)), as: UTF8.self)
            case 4: host = Address.text(AF_INET6, [UInt8](try await local.read(16)))
            default: throw LiveTunnelError.protocolMismatch
            }
            let port = [UInt8](try await local.read(2))
            return (host, UInt16(port[0]) << 8 | UInt16(port[1]))
        }
    }
}

// MARK: 连接的 async 小件

extension NWConnection {
    /// 等到连上；失败、被取消、TLS 握不上（密钥不对）、`limit` 内没连上都抛错。别的 `waiting`（连不上、本地网络权限没给）不算失败、照等：
    /// 权限弹窗出来时系统先把连接挂在这里，允许后自己重试。挂着时的原因报给 `waiting`（`LiveLink` 据此分出"权限没给"）。
    nonisolated func established(within limit: Duration, waiting: (@Sendable (NWPath.UnsatisfiedReason) -> Void)? = nil) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            let once = Mutex(Optional(done))
            stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: once.withLock { $0.take() }?.resume()
                case .waiting(.tls(let status)): once.withLock { $0.take() }?.resume(throwing: NWError.tls(status))
                case .waiting: if let reason = self?.currentPath?.unsatisfiedReason { waiting?(reason) }
                case .failed(let error): once.withLock { $0.take() }?.resume(throwing: error)
                case .cancelled: once.withLock { $0.take() }?.resume(throwing: CancellationError())
                default: break
                }
            }
            start(queue: LiveTunnel.queue)
            LiveTunnel.queue.asyncAfter(deadline: .now() + limit.seconds) { [weak self] in
                guard let pending = once.withLock({ $0.take() }) else { return }
                self?.stateUpdateHandler = nil
                pending.resume(throwing: LiveTunnelError.timedOut)
            }
        }
    }

    nonisolated func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { done in
            receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { done.resume(throwing: error) } else if let data, data.count == count { done.resume(returning: data) } else { done.resume(throwing: LiveTunnelError.closed) }
            }
        }
    }

    nonisolated func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in if let error { done.resume(throwing: error) } else { done.resume() } })
        }
    }

    /// 读写挂住的连接到时取消（读写随之以错误返回）：手机、Mac 都不为一条不说话的连接一直等。
    nonisolated func bounded<T: Sendable>(_ limit: Duration, _ work: () async throws -> T) async throws -> T {
        let timer = Task { [weak self] in
            try await Task.sleep(for: limit)
            self?.cancel()
        }
        defer { timer.cancel() }
        return try await work()
    }
}
