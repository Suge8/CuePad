import CueStore
import CueSync
import Foundation
import Observation
import os
import Synchronization

/// 门铃：经自建中转（`relay/server.ts`）与同一个人的其它设备保持一条长连接。本机的一批改动被 iCloud 收下就按一下，
/// 别的设备听到就去 iCloud 拉一次；门铃不带内容，数据只有 iCloud 一份。通着（`isLive`）时按节奏的拉取降为兜底，连不上或断了换回快档（`SyncPoller.Cadence`）。
///
/// 何时连由 App 定（`AppServices.startRelay`）：`run` 期间想连就连着；`pause` 起不想连，`settle` 等按出去的门铃发完再断，
/// 其间 `resume` 了就不断；换了 iCloud 账号 `reconnect` 换房间。不想连着时又有改动被收下（手机在后台点了实时活动上的"允许一次"），
/// 短连一次（iOS 在后台任务里）：入房、按完就断，不等回前台，对方不必等兜底那一拉。
/// 密钥要认过账号才取得到（`CloudSync.relaySecret`）：没登录 iCloud 时连接停在取密钥上，不重试。取到就记着（`known`），之后的连接不再先去 iCloud 取一趟；
/// 用记着的那份入了房再去取一次核对，变了（这个账号的 iCloud 数据被清掉、密钥重新生成过）就按新的重连。
/// 断了按退避加抖动重连（`retry`），网络恢复时不等退避；每次入房先补按欠下的门铃（`ring`），同时开始心跳、收门铃并拉一次：
/// 没连着的那段时间（包括启动到第一次连上）的门铃听不到。
/// 心跳用 WebSocket 协议层的 ping，每 `pingInterval` 一次，`pongLimit` 内没回就断开重连：静默断线最迟 `silenceLimit` 发现。
/// 用 URLSessionWebSocketTask：带系统代理设置、协议层 ping、自动回中转的 ping；连接是 wss（证书由系统校验）。
@Observable
final class Relay {
    /// 门铃此刻通着：入了房间，心跳有回应。
    private(set) var isLive = false

    @ObservationIgnored private let endpoint: URL
    @ObservationIgnored private let credentials: @MainActor () async throws -> RelayCredentials
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var rang: (@MainActor () async -> Void)?
    /// 这个账号的房间与签名（密钥派生的）：取到一次就记着，换账号（`reconnect`）时清掉。
    @ObservationIgnored private var known: RelayCredentials?
    /// 保持连接的任务（断了自己重连）；断开着时为 nil。
    @ObservationIgnored private var connection: Task<Void, Never>?
    /// 最后一个按出去的门铃（之前的都已发完或失败）：`settle` 与短连等它。
    @ObservationIgnored private var sending: Task<Void, Never>?
    /// 有改动被收下时门铃没通（或没按出去），入房后先补按一次。
    @ObservationIgnored private var owesRing = false
    /// 此刻想不想连着（`resume` 为真、`pause` 为假）：`settle` 只在仍不想连时断开。
    @ObservationIgnored private var wanted = false

    nonisolated static let pingInterval = Duration.seconds(10)
    nonisolated static let pongLimit = Duration.seconds(5)
    /// 心跳察觉静默断线的上限，也是门铃通着时按节奏拉取降到的兜底间隔（`AppServices.doorbellFallback`）：兜底只补门铃自己察觉不到的丢失
    /// （对方按出去的那一下在路上没了、中转重启），察觉得到的断（断线、重连）当场换回快档、入房先拉一次，察觉不到的也不比它更晚。
    nonisolated static let silenceLimit = pingInterval + pongLimit
    /// 连上、入房的时限。
    nonisolated static let handshakeLimit = Duration.seconds(15)
    /// 重连的退避：1 秒起，至多 `Backoff.waitingCap`（中转恢复后至多再等这么久就连回来，门铃不通时一直按 2 秒拉）。
    static let retry = Backoff(first: .seconds(1), cap: Backoff.waitingCap)
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
    /// 下次入房先补按：对方的拉取降为兜底后，丢一下就要等到兜底那一拉。不想连着的这时短连一次去补按。
    func ring() {
        guard isLive, let socket else {
            owesRing = true
            connect()
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
                Self.log.notice("门铃没按出去，入房后补按：\(error.brief, privacy: .public)")
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
        known = nil
        guard connection != nil else { return }
        await disconnect()
        connect()
    }

    /// 想连着、或欠着门铃时连（后者是短连：iOS 在后台任务里，按完就断）。
    private func connect() {
        guard connection == nil, let rang, wanted || owesRing else { return }
        let done: @MainActor @Sendable () -> Void
        #if os(iOS)
        if wanted { done = {} } else { done = BackgroundWork.begin() }
        #else
        done = {}
        #endif
        connection = Task {
            await stayConnected(rang)
            done()
        }
    }

    private func disconnect() async {
        guard let connection else { return }
        self.connection = nil
        connection.cancel()
        await connection.value
    }

    /// 想连着就一直连着，只为补按门铃连上的按完就走；断了按退避重连。自己结束（不是被 `disconnect` 取消）时清掉 `connection`。
    private func stayConnected(_ rang: @escaping @MainActor () async -> Void) async {
        var retry = Self.retry
        while !Task.isCancelled, wanted || owesRing {
            let began = ContinuousClock.now
            do {
                try await session(rang)
            } catch where !Task.isCancelled {
                Self.log.notice("门铃断了：\(error.brief, privacy: .public)")
            } catch {}
            if isLive, ContinuousClock.now - began >= Self.steady { retry.reset() }
            isLive = false
            guard !Task.isCancelled, wanted || owesRing else { break }
            await Self.wait(upTo: retry.next())
        }
        if !Task.isCancelled { connection = nil }
    }

    /// 等 `delay`，其间网络恢复（`NetworkReturns`）或任务被取消就提前返回。
    private nonisolated static func wait(upTo delay: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: delay) }
            group.addTask {
                var returns = NetworkReturns.stream().makeAsyncIterator()
                _ = await returns.next()
            }
            await group.next()
            group.cancelAll()
        }
    }

    /// 一次连接：握手、入房、补按欠下的门铃；不想连着的按完就返回，想连着的同时拉一次、收门铃、发心跳，直到断开（抛出）或被取消。
    private func session(_ rang: @escaping @MainActor () async -> Void) async throws {
        let remembered = known
        let credentials: RelayCredentials
        if let remembered { credentials = remembered } else { credentials = try await self.credentials() }
        known = credentials
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
            guard wanted else {
                await sending?.value
                return
            }
            Task { await rang() }  // 补上没连着时听不到的；心跳与收门铃不等它
            if let remembered { Task { await recheck(remembered) } }
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

    /// 用记着的那份入了房：再取一次密钥核对，换过了就忘掉旧的、重取重连（只在其间没换账号时）。
    private func recheck(_ remembered: RelayCredentials) async {
        guard let fresh = try? await credentials(), fresh.room != remembered.room, known?.room == remembered.room else { return }
        Self.log.notice("门铃的密钥换过了，换房间重连")
        await reconnect()
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
