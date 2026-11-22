import CryptoKit
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
/// 连接的状态只在 `phase`：同一时刻至多一条连接任务，旧的还在收尾（`.closing`）时 `resume`、`ring` 不另起新的，收尾完了再按那时想不想连来决定，
/// 所以旧任务的收尾碰不到新连接。几处同时断开（换账号重连时 `run` 被取消）都等同一个收尾；
/// `run` 结束后不再连（`rang` 清掉），收尾完的重连也不起：没人能再取消的连接不会留下。
/// 用 URLSessionWebSocketTask：带系统代理设置、协议层 ping、自动回中转的 ping。
@Observable
final class Relay {
    private enum Phase {
        case off
        case connecting(Task<Void, Never>)
        case live(Task<Void, Never>, URLSessionWebSocketTask)
        case closing(Task<Void, Never>)
    }

    private var phase = Phase.off
    var isLive: Bool { if case .live = phase { true } else { false } }
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
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private var rang: (@MainActor () async -> Void)?
    @ObservationIgnored private var known: RelayCredentials?
    var liveTunnelKey: SymmetricKey? { known?.tunnelKey }
    @ObservationIgnored private var sending: Task<Void, Never>?
    @ObservationIgnored private var owesRing = false
    @ObservationIgnored private var wanted = false
    @ObservationIgnored private var downSince: ContinuousClock.Instant?

    nonisolated static let pingInterval = Duration.seconds(10)
    nonisolated static let pongLimit = Duration.seconds(5)
    nonisolated static let silenceLimit = pingInterval + pongLimit
    nonisolated static let handshakeLimit = Duration.seconds(15)
    static let retry = Backoff(first: .seconds(1), cap: Backoff.waitingCap)
    static let steady = Duration.seconds(30)
    private nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "relay")

    init(endpoint: URL, device: String, credentials: @escaping @MainActor () async throws -> RelayCredentials) {
        voiceDevice = VoiceDeviceID(device)
        self.endpoint = endpoint
        self.credentials = credentials
        session = URLSession(configuration: .ephemeral)
    }

    func ring() {
        guard case .live(_, let socket) = phase else {
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

    func run(connected: Bool, rang: @escaping @MainActor () async -> Void) async {
        self.rang = rang
        if connected { resume() }
        let (cancelled, keep) = AsyncStream<Never>.makeStream()
        for await _ in cancelled {}
        withExtendedLifetime(keep) {}
        self.rang = nil
        await disconnect(thenConnect: false)
    }

    func resume() {
        wanted = true
        connect()
    }

    func pause() {
        wanted = false
    }

    func settle() async {
        await sending?.value
        guard !wanted else { return }
        await disconnect(thenConnect: true)
    }

    func reconnect() async {
        voiceConnection?.close(.accountChanged)
        known = nil
        guard case .off = phase else { return await disconnect(thenConnect: true) }
    }

    private func connect() {
        guard case .off = phase, let rang, wanted || owesRing else { return }
        let done: @MainActor @Sendable () -> Void
        #if os(iOS)
        if wanted { done = {} } else { done = BackgroundWork.begin() }
        #else
        done = {}
        #endif
        phase = .connecting(Task {
            await stayConnected(rang)
            done()
        })
    }

    private func disconnect(thenConnect: Bool) async {
        switch phase {
        case .connecting(let task), .live(let task, _):
            task.cancel()
            phase = .closing(task)
        case .off, .closing: break
        }
        guard case .closing(let task) = phase else { return }
        await task.value
        if case .closing(task) = phase { phase = .off }
        if thenConnect { connect() }
    }

    private func stayConnected(_ rang: @escaping @MainActor () async -> Void) async {
        var retry = Self.retry
        while !Task.isCancelled, wanted || owesRing {
            await DebugHooks.relayHold()
            let began = ContinuousClock.now
            do {
                try await session(rang)
            } catch where !Task.isCancelled {
                if downSince == nil {
                    downSince = .now
                    Self.log.notice("门铃断了，按退避重连：\(error.brief, privacy: .public)")
                }
            } catch {}
            if case .live(let task, _) = phase {
                if ContinuousClock.now - began >= Self.steady { retry.reset() }
                phase = .connecting(task)
            }
            guard !Task.isCancelled, wanted || owesRing else { break }
            await Self.wait(upTo: retry.next())
        }
        if case .connecting = phase { phase = .off }
    }

    private nonisolated static func wait(upTo delay: Duration) async {
        let returns = NetworkReturns.stream()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: delay) }
            group.addTask {
                var returns = returns.makeAsyncIterator()
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
        DebugHooks.relaySocket(socket)
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
        }
        try await withTaskCancellationHandler {
            socket.resume()
            let voice = try await Self.handshake(socket, credentials, device: voiceDevice, emit: { [voiceFeed] in voiceFeed.continuation.yield($0) })
            voiceConnection = voice
            voiceAvailability(voice.map { .ready(endpoint: $0.crypto.claim.endpoint) } ?? .unsupported)
            guard case .connecting(let task) = phase else { return }
            phase = .live(task, socket)
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
            Task { await rang() }
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
                defer { socket.cancel(with: .goingAway, reason: nil) }
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
                    if response.t == "ring" { continue }
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
            if case .success = await watchdog.result { throw RelayError.handshakeTimeout }
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

private nonisolated final class Pong: Sendable {
    private let state = Mutex<ContinuousClock.Instant?>(nil)
    var last: ContinuousClock.Instant? { state.withLock { $0 } }
    func heard(at instant: ContinuousClock.Instant) { state.withLock { $0 = instant } }
}
