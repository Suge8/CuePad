import CueStore
import Foundation
import Network
import Observation
import os
import Synchronization

/// 门铃：经自建中转（`relay/server.ts`）与同一个人的其它设备保持一条长连接。本机的一批改动被 iCloud 收下就按一下，
/// 别的设备听到就去 iCloud 拉一次；门铃不带内容，数据只有 iCloud 一份。通着（`isLive`）时按节奏的拉取降为兜底，连不上或断了换回快档（`SyncPoller.Cadence`）。
///
/// 何时连由 App 定（`AppServices.startRelay`）：`run` 期间想连就连着；`pause` 起不想连，`settle` 等按出去的门铃发完再断，
/// 其间 `resume` 了就不断；换了 iCloud 账号 `reconnect` 换房间。
/// 断了按退避加抖动重连，网络恢复时不等退避；每次入房先补按欠下的门铃（`ring`）、再拉一次：没连着的那段时间（包括启动到第一次连上）的门铃听不到。
/// 心跳用 WebSocket 协议层的 ping，每 `pingInterval` 一次，`pongLimit` 内没回就断开重连：静默断线最迟约 15 秒发现。
/// 用 URLSessionWebSocketTask：带系统代理设置、协议层 ping；连接是 wss（证书由系统校验）。
@Observable
final class Relay {
    /// 门铃此刻通着：入了房间，心跳有回应。
    private(set) var isLive = false

    @ObservationIgnored private let endpoint: URL
    @ObservationIgnored private let credentials: @MainActor () async throws -> RelayCredentials
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var rang: (@MainActor () async -> Void)?
    /// 保持连接的任务（断了自己重连）；断开着时为 nil。
    @ObservationIgnored private var connection: Task<Void, Never>?
    /// 最后一个按出去的门铃（之前的都已发完或失败）：`suspend` 等它。
    @ObservationIgnored private var sending: Task<Void, Never>?
    /// 有改动被收下时门铃没通（或没按出去），入房后先补按一次。
    @ObservationIgnored private var owesRing = false
    /// 此刻想不想连着（`resume` 为真、`pause` 为假）：`settle` 只在仍不想连时断开。
    @ObservationIgnored private var wanted = false

    nonisolated static let pingInterval = Duration.seconds(10)
    nonisolated static let pongLimit = Duration.seconds(5)
    /// 连上、入房的时限。
    nonisolated static let handshakeLimit = Duration.seconds(15)
    static let firstRetry = Duration.seconds(1)
    static let maxRetry = Duration.seconds(60)
    /// 连上后通了这么久才算稳定，退避从头算；更短就断的（中转刚起就挂、被网络掐掉）接着加长。
    static let steady = Duration.seconds(30)
    private nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "relay")

    /// `host` 是中转的主机（可带端口），连 `wss://<host>/v1/<房间号>`。
    init(host: String, credentials: @escaping @MainActor () async throws -> RelayCredentials) {
        endpoint = URL(string: "wss://\(host)/v1")!
        self.credentials = credentials
        session = URLSession(configuration: .ephemeral)
    }

    /// 本机的一批改动已被 iCloud 收下：通着就按一下门铃（排在前一个后面发）；不通（正在重连、手机在后台）或没按出去的记下欠一次，
    /// 下次入房先补按：对方的拉取降为兜底后，丢一下就要等到兜底那一拉。
    func ring() {
        guard isLive, let socket else {
            owesRing = true
            return
        }
        let previous = sending
        sending = Task {
            await previous?.value
            do {
                try await socket.send(.string(#"{"t":"ring"}"#))
                Self.log.info("按了门铃")
            } catch {
                owesRing = true
                Self.log.notice("门铃没按出去，入房后补按：\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 保持连接直到任务取消（`connected` 为假时先不连，等 `resume`）。门铃响了（以及每次入房时）调 `rang`。
    func run(connected: Bool, rang: @escaping @MainActor () async -> Void) async {
        self.rang = rang
        if connected { resume() }
        let (cancelled, keep) = AsyncStream<Never>.makeStream()
        for await _ in cancelled {}  // 任务取消时结束
        withExtendedLifetime(keep) {}
        await disconnect()
    }

    /// 想连着：没连着就连（还没 `run` 时只记下）。
    func resume() {
        wanted = true
        connect()
    }

    /// 不想再连着（如手机进后台），连接留到 `settle`：本机还在传的改动收下后还要按门铃。
    func pause() {
        wanted = false
    }

    /// `pause` 之后：等已经按出去的门铃发完，仍不想连着就断开，返回时连接已关。
    func settle() async {
        await sending?.value
        guard !wanted else { return }
        await disconnect()
    }

    /// 换了 iCloud 账号：连着的那条在旧账号的房间里，断开后按新账号的密钥重连。
    func reconnect() async {
        guard connection != nil else { return }
        await disconnect()
        if wanted { connect() }
    }

    private func connect() {
        guard connection == nil, let rang else { return }
        connection = Task { await self.stayConnected(rang) }
    }

    private func disconnect() async {
        guard let connection else { return }
        self.connection = nil
        connection.cancel()
        await connection.value
    }

    private func stayConnected(_ rang: @escaping @MainActor () async -> Void) async {
        let network = NetworkReturns()
        defer { network.cancel() }
        var failures = 0
        while !Task.isCancelled {
            let began = ContinuousClock.now
            do {
                try await session(rang)
            } catch where !Task.isCancelled {
                Self.log.notice("门铃断了：\(String(describing: error), privacy: .public)")
            } catch {}
            let lasted = isLive && ContinuousClock.now - began >= Self.steady
            isLive = false
            guard !Task.isCancelled else { return }
            failures = lasted ? 1 : failures + 1
            await network.wait(upTo: Self.retryDelay(after: failures))
        }
    }

    /// 第 n 次失败后等多久：1、2、4…秒到 `maxRetry`，再在后一半里随机取（一群设备不同时打回来）。
    static func retryDelay(after failures: Int) -> Duration {
        let ceiling = min(firstRetry * (1 << min(failures - 1, 6)), maxRetry)
        return ceiling * Double.random(in: 0.5...1)
    }

    /// 一次连接：握手、入房、先拉一次，之后收门铃、发心跳，直到断开（抛出）或被取消。
    private func session(_ rang: @escaping @MainActor () async -> Void) async throws {
        let credentials = try await credentials()
        let socket = session.webSocketTask(with: endpoint.appending(path: credentials.room))
        self.socket = socket
        defer {
            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket { self.socket = nil }
        }
        try await withTaskCancellationHandler {
            socket.resume()
            try await Self.handshake(socket, credentials)
            isLive = true
            Self.log.notice("门铃通了")
            if owesRing {
                owesRing = false
                ring()
            }
            await rang()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await Self.heartbeat(socket) }
                group.addTask {
                    while true {
                        guard try await Self.frame(from: socket).t == "ring" else { throw RelayError.unexpectedFrame }
                        Self.log.info("门铃响了")
                        await rang()
                    }
                }
                defer { socket.cancel(with: .goingAway, reason: nil) }  // 一个先结束，另一个等在这条连接上的也随之结束
                try await group.next()
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    /// 收中转的随机数、签名回去、等它说入了房间；`handshakeLimit` 内没走完就断开。
    private static func handshake(_ socket: URLSessionWebSocketTask, _ credentials: RelayCredentials) async throws {
        let watchdog = Task {
            try await Task.sleep(for: handshakeLimit)
            socket.cancel(with: .goingAway, reason: nil)
        }
        do {
            let challenge = try await frame(from: socket)
            guard challenge.t == "challenge", let nonce = challenge.n else { throw RelayError.unexpectedFrame }
            try await socket.send(.string(#"{"t":"auth","s":"\#(try credentials.sign(nonce))"}"#))
            guard try await frame(from: socket).t == "ready" else { throw RelayError.unexpectedFrame }
            watchdog.cancel()
        } catch {
            watchdog.cancel()
            if case .success = await watchdog.result { throw RelayError.handshakeTimeout }  // 是时限到了断的，不是别的错
            throw error
        }
    }

    /// 每 `pingInterval` 发一个 ping，`pongLimit` 内没回就抛出（连接静默断了：中转挂了、网络换了、睡眠醒来）。
    private nonisolated static func heartbeat(_ socket: URLSessionWebSocketTask) async throws {
        let pong = Pong()
        while true {
            let sent = ContinuousClock.now
            socket.sendPing { error in if error == nil { pong.heard(at: .now) } }
            try await Task.sleep(for: pongLimit)
            guard let heard = pong.last, heard >= sent else { throw RelayError.silent }
            try await Task.sleep(until: sent + pingInterval)
        }
    }

    private struct Frame: Decodable {
        var t: String
        var n: String?
    }

    private nonisolated static func frame(from socket: URLSessionWebSocketTask) async throws -> Frame {
        guard case .string(let text) = try await socket.receive() else { throw RelayError.unexpectedFrame }
        return try JSONDecoder().decode(Frame.self, from: Data(text.utf8))
    }
}

/// 最近一次 ping 的回应时刻（URLSession 的回调线程写，心跳读）。
private nonisolated final class Pong: Sendable {
    private let state = Mutex<ContinuousClock.Instant?>(nil)
    var last: ContinuousClock.Instant? { state.withLock { $0 } }
    func heard(at instant: ContinuousClock.Instant) { state.withLock { $0 = instant } }
}

/// 网络恢复（路径从不可用变为可用）时提前结束重连前的等待。
private final class NetworkReturns {
    private let monitor = NWPathMonitor()
    private var satisfied: Bool?
    private var waiter: CheckedContinuation<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.update(satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "\(AppIdentity.id).relay.network"))
    }

    private func update(_ satisfied: Bool) {
        if satisfied, self.satisfied == false { wake() }
        self.satisfied = satisfied
    }

    /// 等 `delay`，其间网络恢复或任务被取消就提前返回。
    func wait(upTo delay: Duration) async {
        let timer = Task {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            wake()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor in self.wake() }
        }
        timer.cancel()
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }

    func cancel() { monitor.cancel() }
}
