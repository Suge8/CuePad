import CryptoKit
import CueStore
import Darwin
import Foundation
import Network
import OSLog
import Synchronization

private nonisolated let log = Logger(subsystem: AppIdentity.id, category: "live")

extension LiveTunnel {
    nonisolated struct Route: Sendable {
        let key: SymmetricKey
        let ticket: Data
        let mac: NWEndpoint
        let addresses: Set<String>
        let id = UUID()

        func dial(host: String, port: UInt16, report: AsyncStream<Break>.Continuation) async throws -> NWConnection {
            let remote = NWConnection(to: mac, using: LiveTunnel.parameters(key: key))
            let answer: Answer
            do {
                try await remote.established(within: .seconds(4))
                try await remote.write(Request(ticket: ticket, host: host, port: port).encoded)
                answer = try await remote.bounded(.seconds(5)) { try await remote.read(1) }.first.flatMap(Answer.init) ?? .refused
            } catch {
                remote.cancel()
                report.yield(.init(route: id, answer: nil))
                throw error
            }
            guard answer == .open else {
                remote.cancel()
                if answer == .ticket { report.yield(.init(route: id, answer: answer)) }
                log.notice("活预览去 Mac 的 \(host, privacy: .public):\(port) 没通：\(String(describing: answer), privacy: .public)")
                throw LiveTunnelError.answer(answer)
            }
            return remote
        }
    }

    nonisolated struct Break: Sendable {
        let route: UUID
        let answer: Answer?
    }

    nonisolated final class Proxy: Sendable {
        let user = "cuepad"
        let password = UUID().uuidString
        private let listener: NWListener
        private let route = Mutex<Route?>(nil)
        private let mirrors = Mutex<[UInt16: Mirror]>([:])
        let mirrored: AsyncStream<Mirrored>
        private let mirroring: AsyncStream<Mirrored>.Continuation

        struct Mirrored: Equatable, Sendable {
            var open: Set<UInt16> = []
            var taken: Set<UInt16> = []
        }

        private struct Mirror {
            let id = UUID()
            var listeners: [NWListener] = []
            var ready = 0
            var failed = false
        }

        private static let remirror = Duration.seconds(3)
        let broken: AsyncStream<Break>
        private let report: AsyncStream<Break>.Continuation

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            listener = try NWListener(using: parameters)
            (broken, report) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
            (mirrored, mirroring) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
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
            mirror([])
            report.finish()
            mirroring.finish()
        }

        /// 把 Mac 放行的这几个口照搬到手机自己的回环上（同一个端口号），接进来的原样送进隧道，到 Mac 的 localhost 同号口。
        /// 真机上网页视图连 localhost、127.0.0.1、::1 不经代理、直接连手机自己（实测 iOS 27.3：`ProxyConfiguration` 对回环目标不生效，
        /// `allowFailover = false` 也一样，页面一直"连接被拒绝"；换成 Mac 的局域网地址才走代理），所以回环地址的页面靠它。页面看到的还是原来的地址：
        /// 同源、安全上下文、页面里写死的 localhost:端口（另一个口上的接口、热更新的连接）都照旧。同 SSH 与编辑器远程开发的端口转发。
        /// 回环口带不了口令：预览看得见的这段时间（收起、进后台就关），手机上别的应用连得上这几个口，同 Mac 上本机进程连得上开发服务一样；
        /// 所以 Mac 只放行网页用得上的口（答 HTTP 的，`LiveServers.ports`），会话起的数据库这类不在里面。
        /// 模拟器不开：它和 Mac 共用回环，那个口就是开发服务自己（开了 Mac 连回 localhost 会连到这里，绕成圈）。
        /// 回环口是整台设备共用的：被占着的（iPad 另一个窗口的预览开着同号口、别的应用）开不了，那个口上的页面不载（载了连到的是占着它的别人），
        /// 报在 `mirrored` 里，占着的走了自己接上。
        func mirror(_ ports: Set<UInt16>) {
            #if !targetEnvironment(simulator)
            let gone = mirrors.withLock { mirrors in
                let gone = mirrors.filter { !ports.contains($0.key) }
                for port in gone.keys { mirrors[port] = nil }
                for port in ports where mirrors[port] == nil { mirrors[port] = listen(port) }
                mirroring.yield(Self.mirrored(mirrors))
                return gone.values.flatMap(\.listeners)
            }
            for listener in gone { listener.cancel() }
            #endif
        }

        private static func mirrored(_ mirrors: [UInt16: Mirror]) -> Mirrored {
            Mirrored(open: Set(mirrors.filter { !$0.value.failed && $0.value.ready == 2 }.keys), taken: Set(mirrors.filter(\.value.failed).keys))
        }

        private func listen(_ port: UInt16, again: Bool = false) -> Mirror {
            var mirror = Mirror()
            let id = mirror.id
            mirror.listeners = [NWEndpoint.Host.ipv4(.loopback), .ipv6(.loopback)].compactMap { host -> NWListener? in
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: host, port: .init(rawValue: port)!)
                parameters.allowLocalEndpointReuse = true
                guard let listener = try? NWListener(using: parameters) else { return nil }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return connection.cancel() }
                    let route = route.withLock { $0 }
                    Task { await Self.forward(connection, port: port, route: route, report: self.report) }
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready: self?.settle(port, id, failed: false)
                    case .failed(let error):
                        if !again { log.notice("活预览在手机回环上开不了 \(port) 口：\(String(describing: error), privacy: .public)") }
                        self?.settle(port, id, failed: true)
                    default: break
                    }
                }
                listener.start(queue: LiveTunnel.queue)
                return listener
            }
            return mirror
        }

        private func settle(_ port: UInt16, _ id: UUID, failed: Bool) {
            let closing = mirrors.withLock { mirrors -> [NWListener]? in
                guard var mirror = mirrors[port], mirror.id == id, !mirror.failed else { return nil }
                if failed { mirror.failed = true } else { mirror.ready += 1 }
                mirrors[port] = mirror
                mirroring.yield(Self.mirrored(mirrors))
                return failed ? mirror.listeners : nil
            }
            guard let closing else { return }
            for listener in closing { listener.cancel() }
            LiveTunnel.queue.asyncAfter(deadline: .now() + Self.remirror.seconds) { [weak self] in
                guard let self else { return }
                mirrors.withLock { mirrors in
                    guard mirrors[port]?.id == id else { return }
                    mirrors[port] = listen(port, again: true)
                }
            }
        }

        private static func forward(_ local: NWConnection, port: UInt16, route: Route?, report: AsyncStream<Break>.Continuation) async {
            do {
                try await local.established(within: .seconds(5))
                guard let route else { return local.cancel() }
                let remote = try await route.dial(host: "localhost", port: port, report: report)
                Splice(local, remote) { remoteFailed in if remoteFailed { report.yield(.init(route: route.id, answer: nil)) } }.start()
            } catch {
                local.cancel()
            }
        }

        func configuration(port: UInt16) -> ProxyConfiguration {
            var proxy = ProxyConfiguration(socksv5Proxy: .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!))
            proxy.applyCredential(username: user, password: password)
            proxy.allowFailover = false
            return proxy
        }

        static func isMac(_ host: String, addresses: Set<String>) -> Bool {
            let host = host.lowercased()
            if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || addresses.contains(host) { return true }
            var v4 = in_addr()
            return inet_pton(AF_INET, host, &v4) == 1 && UInt32(bigEndian: v4.s_addr) >> 24 == 127
        }

        private static func serve(_ local: NWConnection, user: String, password: String, route: Route?, report: AsyncStream<Break>.Continuation) async {
            do {
                try await local.established(within: .seconds(5))
                let (host, port) = try await local.bounded(.seconds(5)) { try await handshake(local, user: user, password: password) }
                let remote: NWConnection
                if isMac(host, addresses: route?.addresses ?? []) {
                    guard let route else { return refuse(local, 3) }
                    do {
                        remote = try await route.dial(host: host, port: port, report: report)
                    } catch LiveTunnelError.answer(let answer) {
                        return refuse(local, answer == .refused ? 2 : 5)
                    } catch {
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
                let mac = isMac(host, addresses: route?.addresses ?? []) ? route?.id : nil
                Splice(local, remote) { remoteFailed in if remoteFailed, let mac { report.yield(.init(route: mac, answer: nil)) } }.start()
            } catch {
                local.cancel()
            }
        }

        private static func refuse(_ local: NWConnection, _ code: UInt8) {
            local.send(content: Data([5, code, 0, 1, 0, 0, 0, 0, 0, 0]), completion: .contentProcessed { _ in local.cancel() })
        }

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

    nonisolated func bounded<T: Sendable>(_ limit: Duration, _ work: () async throws -> T) async throws -> T {
        let timer = Task { [weak self] in
            try await Task.sleep(for: limit)
            self?.cancel()
        }
        defer { timer.cancel() }
        return try await work()
    }
}
