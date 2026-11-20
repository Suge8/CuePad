import CueStore
import Foundation

/// 手机、iPad 这头问 Mac（`LiveSignal`）：开着的会话页有没有页面可看，开着的活预览去哪连。会话页看得见时问（`watch`），
/// 那台 Mac 不在线、中转没连上时不问；每 `LiveSignal.renewal` 续问一次，Mac 有变化会主动答。iPad 几个窗口开着同一个会话合成一份问。
/// 答复只在内存里：页面地址是那台 Mac 上的服务，不进库、不同步。
@Observable
final class LiveRemote {
    struct Pages: Equatable, Sendable {
        var pages: [URL]
        var serving: [URL]
        var sent: LiveAddress?
        var door: LiveSignal.Door?
        /// 隧道放行的 Mac 本机端口：手机照搬到自己的回环上（`LiveTunnel.Proxy.mirror`）。
        var ports: [Int]
    }

    /// Mac 答的，按 Pi 的会话 id。没答、答了没有页面、过了 `LiveSignal.lease` 没再答都不在里面。
    private(set) var answers: [String: Pages] = [:]
    /// 问不到那台 Mac 的会话（它不在线、中转说它走了）。
    private(set) var offline: Set<String> = []

    private struct Watch {
        let host: String
        var viewers = 0
        var opens = 0
        var loop: Task<Void, Never>?
        /// 两问之间在等（`pause`）；被催时（`renew`）没在等就记一笔，等的时候不等了。
        var waiting: CheckedContinuation<Void, Never>?
        var owed = false
        var answeredAt: ContinuousClock.Instant?
        var requests: Set<UUID> = []
    }

    @ObservationIgnored private var watches: [String: Watch] = [:]
    @ObservationIgnored private let store: CueStore
    @ObservationIgnored private let signaling: () -> (any VoiceSignaling)?

    init(store: CueStore, signaling: @escaping () -> (any VoiceSignaling)?) {
        self.store = store
        self.signaling = signaling
    }

    /// 这个会话的页（`open`：连同它的活预览）看得见时调，直到所在任务取消。
    func watch(_ sessionID: String, on host: String, open: Bool = false) async {
        var watch = watches[sessionID] ?? Watch(host: host)
        watch.viewers += 1
        if open { watch.opens += 1 }
        let starts = watch.loop == nil
        watches[sessionID] = watch
        if starts { watches[sessionID]?.loop = Task { await self.ask(sessionID) } } else if open { renew(sessionID) }
        let (cancelled, keep) = AsyncStream<Never>.makeStream()
        await withTaskCancellationHandler {
            for await _ in cancelled {}
        } onCancel: { keep.finish() }
        guard var watch = watches[sessionID] else { return }
        watch.viewers -= 1
        if open { watch.opens -= 1 }
        if watch.viewers == 0 {
            watch.loop?.cancel()
            watches[sessionID] = nil
            watch.waiting?.resume()
            answers[sessionID] = nil
            offline.remove(sessionID)
        } else {
            watches[sessionID] = watch
            if open { renew(sessionID) }
        }
    }

    /// 正看着的这个会话在哪台 Mac 上。
    func host(_ sessionID: String) -> String? { watches[sessionID]?.host }

    /// 马上再问一次（打开预览、票据不认了、网络回来了、回到前台）。
    func renew(_ sessionID: String) {
        guard watches[sessionID] != nil else { return }
        if let waiting = watches[sessionID]?.waiting {
            watches[sessionID]?.waiting = nil
            waiting.resume()
        } else {
            watches[sessionID]?.owed = true
        }
    }

    private func ask(_ sessionID: String) async {
        let channel = VoiceSessionID(UUID())
        while !Task.isCancelled, watches[sessionID] != nil {
            await send(sessionID, channel: channel)
            await pause(sessionID)
            if let at = watches[sessionID]?.answeredAt, ContinuousClock.now - at > LiveSignal.lease { answers[sessionID] = nil }
        }
    }

    /// 等 `renewal` 或被催，先到的算。
    private func pause(_ sessionID: String) async {
        guard watches[sessionID]?.owed == false else {
            watches[sessionID]?.owed = false
            return
        }
        let timer = Task { [weak self] in
            guard (try? await Task.sleep(for: LiveSignal.renewal)) != nil else { return }
            self?.renew(sessionID)
        }
        await withCheckedContinuation { waiting in
            if watches[sessionID] == nil { waiting.resume() } else { watches[sessionID]?.waiting = waiting }
        }
        timer.cancel()
    }

    private func send(_ sessionID: String, channel: VoiceSessionID) async {
        guard let watch = watches[sessionID] else { return }
        guard let signaling = signaling(), case .ready = signaling.voiceAvailability, (try? await store.macOnline(watch.host)) == true else {
            return unreachable(sessionID)
        }
        let request = UUID()
        watches[sessionID]?.requests.insert(request)
        do {
            let peer = try await signaling.resolveVoicePeer(VoiceDeviceID(watch.host))
            let open = (watches[sessionID]?.opens ?? 0) > 0
            try await signaling.sendVoice(.live(signal: .watch(request: request, session: sessionID, open: open)), session: channel, to: peer)
        } catch {
            unreachable(sessionID)
        }
    }

    /// 请 Mac 把这个会话亮在最前（`LiveSignal.show`），接着要拉起 UU 远程：最多等 `showWait`，发不出、中转没连上都不拦。
    /// 等的是发出去，不等 Mac 做完：App 一被 UU 顶到后台，中转连接就可能停下。
    func show(_ sessionID: String, on host: String) async {
        guard let signaling = signaling(), case .ready = signaling.voiceAvailability else { return }
        let (sent, done) = AsyncStream<Never>.makeStream()
        Task {
            if let peer = try? await signaling.resolveVoicePeer(VoiceDeviceID(host)) {
                try? await signaling.sendVoice(.live(signal: .show(request: UUID(), session: sessionID)), session: VoiceSessionID(UUID()), to: peer)
            }
            done.finish()
        }
        let timer = Task {
            try? await Task.sleep(for: Self.showWait)
            done.finish()
        }
        for await _ in sent {}
        timer.cancel()
    }

    /// 请 Mac 把亮出来时铺满的预览放回去（`LiveSignal.back`）。发出去了返回 true；中转没连上、那台 Mac 不在返回 false。
    func back(_ sessionID: String, on host: String) async -> Bool {
        guard let signaling = signaling(), case .ready = signaling.voiceAvailability else { return false }
        do {
            let peer = try await signaling.resolveVoicePeer(VoiceDeviceID(host))
            try await signaling.sendVoice(.live(signal: .back(request: UUID(), session: sessionID)), session: VoiceSessionID(UUID()), to: peer)
            return true
        } catch {
            return false
        }
    }

    /// 平常一问一发约两个中转往返；再长就不等了，钮点下去不能没反应。
    static let showWait = Duration.seconds(1)

    private func unreachable(_ sessionID: String) {
        answers[sessionID] = nil
        offline.insert(sessionID)
    }

    /// 中转收到的活预览帧与连接、对端的去留（`AppServices.liveEvents`）。
    func receive(_ event: VoiceRelayEvent) {
        switch event {
        case .received(let received):
            guard case .live(.pages(_, let sessionID, let pages, let serving, let sent, let door, let ports)) = received.payload,
                  let watch = watches[sessionID], received.header.sender.device == VoiceDeviceID(watch.host) else { return }
            watches[sessionID]?.answeredAt = .now
            offline.remove(sessionID)
            let next = pages.isEmpty ? nil : Pages(pages: pages, serving: serving, sent: sent, door: door, ports: ports ?? pages.compactMap(\.port))
            if answers[sessionID] != next { answers[sessionID] = next }
        case .peerClosed(let endpoint, _):
            for (sessionID, watch) in watches where VoiceDeviceID(watch.host) == endpoint.device { unreachable(sessionID) }
        case .rejected(let header, _):
            guard case .command(let id) = header.purpose, let (sessionID, _) = watches.first(where: { $0.value.requests.contains(id.rawValue) }) else { return }
            unreachable(sessionID)
        case .availability(.ready):
            for sessionID in watches.keys { renew(sessionID) }
        default: break
        }
    }
}
