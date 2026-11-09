import CueStore
import CueSync
import Foundation
import Observation
import os
import Synchronization

/// 门铃：经自建中转（`relay/server.ts`）与同一个人的其它设备保持一条长连接。本机的一批改动被 iCloud 收下就按一下，
/// 别的设备听到就去 iCloud 拉一次；门铃不带内容，数据只有 iCloud 一份。通着（`isLive`）时按节奏的拉取降为兜底，连不上或断了换回快档（`SyncPoller.Cadence`）。
///
/// 不想连着时又有改动被收下（手机在后台点了实时活动上的"允许一次"），短连一次（iOS 在后台任务里）：入房、按完就断，不等回前台，对方不必等兜底那一拉。
/// 密钥要认过账号才取得到（`CloudSync.relaySecret`）：没登录 iCloud 时连接停在取密钥上，不重试。取到就记着（`known`），之后的连接不再先去 iCloud 取一趟；
/// 用记着的那份入了房再去取一次核对，变了（这个账号的 iCloud 数据被清掉、密钥重新生成过）就按新的重连。
/// 每次入房先拉一次：没连着的那段时间（包括启动到第一次连上）的门铃听不到。
/// 同一时刻至多一条连接任务：旧的还在收尾（`closing`）时 `resume`、`ring` 不另起新的，收尾完了再按那时想不想连来决定，
/// 所以旧任务的收尾（`isLive`、`socket`、`connection`）碰不到新连接的状态。几处同时断开（换账号重连时 `run` 被取消）都等同一个收尾；
/// `run` 结束后不再连（`rang` 清掉），收尾完的重连也不起：没人能再取消的连接不会留下。
/// 用 URLSessionWebSocketTask：带系统代理设置、协议层 ping、自动回中转的 ping。
@Observable
final class Relay {
    private(set) var isLive = false
    private(set) var voiceAvailability: VoiceRelayAvailability = .unavailable
    @ObservationIgnored var voiceConnection: RelayVoiceConnection?
    @ObservationIgnored private let voiceDevice: VoiceDeviceID
    @ObservationIgnored private let voiceFeed = AsyncStream<VoiceRelayEvent>.makeStream()
    var voiceEvents: AsyncStream<VoiceRelayEvent> { voiceFeed.stream }

    private func voiceAvailability(_ value: VoiceRelayAvailability) {
        voiceAvailability = value
        voiceFeed.continuation.yield(.availability(value))
    }

    @ObservationIgnored private let endpoint: URL
    @ObservationIgnored private let credentials: @MainActor () async throws -> RelayCredentials
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var rang: (@MainActor () async -> Void)?
    /// 这个账号的房间与签名（密钥派生的）：取到一次就记着，换账号（`reconnect`）时清掉。
    @ObservationIgnored private var known: RelayCredentials?
    @ObservationIgnored private var connection: Task<Void, Never>?
    /// 正在收尾的旧连接任务（`disconnect` 都等它）：这期间不起新的。
    @ObservationIgnored private var closing: Task<Void, Never>?
    /// 最后一个按出去的门铃（之前的都已发完或失败）：`settle` 与短连等它。
    @ObservationIgnored private var sending: Task<Void, Never>?
    /// 有改动被收下时门铃没通（或没按出去），入房后先补按一次。
    @ObservationIgnored private var owesRing = false
    /// 此刻想不想连着（`resume` 为真、`pause` 为假）：`settle` 只在仍不想连时断开。
    @ObservationIgnored private var wanted = false
    /// 断着的这一段从何时起（日志按段记：断了一条、连回来一条，其间每次重连不记）。
    @ObservationIgnored private var downSince: ContinuousClock.Instant?

    nonisolated static let pingInterval = Duration.seconds(10)
    nonisolated static let pongLimit = Duration.seconds(5)
    /// 心跳察觉静默断线的上限，也是门铃通着时按节奏拉取降到的兜底间隔（`AppServices.doorbellFallback`）：兜底只补门铃自己察觉不到的丢失
    /// （对方按出去的那一下在路上没了、中转重启），察觉得到的断（断线、重连）当场换回快档、入房先拉一次，察觉不到的也不比它更晚。
    nonisolated static let silenceLimit = pingInterval + pongLimit
    nonisolated static let handshakeLimit = Duration.seconds(15)
    /// 重连的退避：1 秒起，至多 `Backoff.waitingCap`（中转恢复后至多再等这么久就连回来，门铃不通时一直按 2 秒拉）。
    static let retry = Backoff(first: .seconds(1), cap: Backoff.waitingCap)
    /// 连上后通了这么久才算稳定，退避从头算；更短就断的（中转刚起就挂、被网络掐掉）接着加长。
    static let steady = Duration.seconds(30)
    private nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "relay")

    /// `host` 是中转的主机（可带端口），连 `wss://<host>/v1/<房间号>`。
    init(host: String, device: String, credentials: @escaping @MainActor () async throws -> RelayCredentials) {
        voiceDevice = VoiceDeviceID(device)
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
        self.rang = nil  // 不再连：收尾期间别处等完的重连（`thenConnect`）也不起
        await disconnect(thenConnect: false)
    }

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
        voiceConnection?.close(.background)
        await disconnect(thenConnect: true)
    }

    /// 换了 iCloud 账号：连着的那条在旧账号的房间里，断开后按新账号的密钥重连。
    func reconnect() async {
        voiceConnection?.close(.accountChanged)
        known = nil
        guard connection != nil else { return }
        await disconnect(thenConnect: true)
    }

    private func connect() {
        guard connection == nil, closing == nil, let rang, wanted || owesRing else { return }
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

    /// 断开并等旧任务收尾。`thenConnect`：收尾期间 `resume`、`ring` 来过的（这时才不被挡）按此刻想不想连决定要不要连。
    private func disconnect(thenConnect: Bool) async {
        if let connection {
            self.connection = nil
            connection.cancel()
            closing = connection
        }
        guard let closing else { return }
        await closing.value
        if self.closing == closing { self.closing = nil }
        if thenConnect { connect() }
    }

    /// 自己结束（不是被 `disconnect` 取消）时清掉 `connection`。
    private func stayConnected(_ rang: @escaping @MainActor () async -> Void) async {
        var retry = Self.retry
        while !Task.isCancelled, wanted || owesRing {
            let began = ContinuousClock.now
            do {
                try await session(rang)
            } catch where !Task.isCancelled {
                if downSince == nil {
                    downSince = .now
                    Self.log.notice("门铃断了，按退避重连：\(error.brief, privacy: .public)")
                }
            } catch {}
            if isLive, ContinuousClock.now - began >= Self.steady { retry.reset() }
            isLive = false
            guard !Task.isCancelled, wanted || owesRing else { break }
            await Self.wait(upTo: retry.next())
        }
        if !Task.isCancelled { connection = nil }
    }

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

    private func session(_ rang: @escaping @MainActor () async -> Void) async throws {
        let remembered = known
        let credentials: RelayCredentials
        if let remembered { credentials = remembered } else { credentials = try await self.credentials() }
        known = credentials
        let socket = session.webSocketTask(with: endpoint.appending(path: credentials.room))
        socket.maximumMessageSize = VoiceSignalFormat.maximumWireBytes
        self.socket = socket
        defer {
            let reason: VoiceEndReason = switch socket.closeCode.rawValue {
            case VoiceSignalFormat.replacedCloseCode: .leaseReplaced
            case 4408: .relayCapacity
            case 4400, 4401: .protocolRejected
            default: .networkFailed
            }
            voiceConnection?.close(reason)
            voiceConnection = nil
            voiceAvailability(.unavailable)
            socket.cancel(with: .goingAway, reason: nil)
            if self.socket === socket { self.socket = nil }
        }
        try await withTaskCancellationHandler {
            socket.resume()
            let voice = try await Self.handshake(socket, credentials, device: voiceDevice, emit: { [voiceFeed] in voiceFeed.continuation.yield($0) })
            voiceConnection = voice
            voiceAvailability(voice.map { .ready(endpoint: $0.crypto.claim.endpoint) } ?? .unsupported)
            isLive = true
            if let downSince {
                Self.log.notice("门铃通了，断了 \((ContinuousClock.now - downSince).seconds, format: .fixed(precision: 1), privacy: .public) 秒")
                self.downSince = nil
            } else {
                Self.log.notice("门铃通了")
            }
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
                        let frame = try await Self.frame(from: socket)
                        switch frame.t {
                        case "ring":
                            Self.log.info("门铃响了")
                            await rang()
                        case "voice":
                            guard let voice, let body = frame.body else { throw RelayError.unexpectedFrame }
                            try await voice.receive(body)
                        default: throw RelayError.unexpectedFrame
                        }
                    }
                }
                defer { socket.cancel(with: .goingAway, reason: nil) }  // 一个先结束，另一个等在这条连接上的也随之结束
                try await group.next()
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    }

    private func recheck(_ remembered: RelayCredentials) async {
        guard let fresh = try? await credentials(), fresh.room != remembered.room, known?.room == remembered.room else { return }
        Self.log.notice("门铃的密钥换过了，换房间重连")
        await reconnect()
    }

    private static func handshake(_ socket: URLSessionWebSocketTask, _ credentials: RelayCredentials,
                                  device: VoiceDeviceID, emit: @escaping (VoiceRelayEvent) -> Void) async throws -> RelayVoiceConnection? {
        let watchdog = Task {
            try await Task.sleep(for: handshakeLimit)
            socket.cancel(with: .goingAway, reason: nil)
        }
        do {
            let challenge = try await frame(from: socket)
            guard challenge.t == "challenge", let nonce = challenge.n else { throw RelayError.unexpectedFrame }
            try await socket.send(.string(#"{"t":"auth","s":"\#(try credentials.sign(nonce))"}"#))
            let ready = try await frame(from: socket)
            guard ready.t == "ready" else { throw RelayError.unexpectedFrame }
            guard ready.voiceVersion == VoiceSignalFormat.version else { watchdog.cancel(); return nil }
            let voice = RelayVoiceConnection(socket: socket, credentials: credentials, challenge: nonce, device: device, emit: emit)
            do {
                try await voice.register(credentials)
                while true {
                    let response = try await frame(from: socket)
                    if response.t == "ring" { continue } // 入房后会统一拉取，握手期间不丢业务事实。
                    guard response.t == "voice", case .registered(let endpoint) = response.body else { throw RelayError.unexpectedFrame }
                    try voice.crypto.acceptRegistration(endpoint)
                    break
                }
            } catch {
                voice.close(socket.closeCode.rawValue == 4408 ? .relayCapacity : .protocolRejected)
                throw error
            }
            watchdog.cancel()
            return voice
        } catch {
            watchdog.cancel()
            if case .success = await watchdog.result { throw RelayError.handshakeTimeout }  // 是时限到了断的，不是别的错
            throw error
        }
    }

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
        var voiceVersion: UInt8?
        var body: VoiceRelayResponse?
    }

    private nonisolated static func frame(from socket: URLSessionWebSocketTask) async throws -> Frame {
        guard case .string(let text) = try await socket.receive() else { throw RelayError.unexpectedFrame }
        guard text.utf8.count <= VoiceSignalFormat.maximumWireBytes else { throw VoiceSignalError.tooLarge }
        return try JSONDecoder().decode(Frame.self, from: Data(text.utf8))
    }
}

/// 最近一次 ping 的回应时刻（URLSession 的回调线程写，心跳读）。
private nonisolated final class Pong: Sendable {
    private let state = Mutex<ContinuousClock.Instant?>(nil)
    var last: ContinuousClock.Instant? { state.withLock { $0 } }
    func heard(at instant: ContinuousClock.Instant) { state.withLock { $0 = instant } }
}
