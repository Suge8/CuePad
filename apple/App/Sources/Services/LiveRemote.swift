import CueStore
import Foundation
#if os(iOS)
import UIKit
#endif

@Observable
final class LiveRemote {
    struct Pages: Equatable, Sendable {
        var pages: [URL]
        var serving: [URL]
        var sent: LiveAddress?
        var door: LiveSignal.Door?
        var ports: [Int]
    }

    private(set) var answers: [String: Pages] = [:]
    private(set) var offline: Set<String> = []

    private struct Watch {
        let host: String
        var viewers = 0
        var opens = 0
        var loop: Task<Void, Never>?
        var waiting: CheckedContinuation<Void, Never>?
        var owed = false
        var answeredAt: ContinuousClock.Instant?
        var requests: Set<UUID> = []
    }

    @ObservationIgnored private var watches: [String: Watch] = [:]
    @ObservationIgnored private var returning: Task<Void, Never>?
    @ObservationIgnored private var backs: Set<UUID> = []
    @ObservationIgnored private let store: CueStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let signaling: () -> (any VoiceSignaling)?

    init(store: CueStore, settings: AppSettings, signaling: @escaping () -> (any VoiceSignaling)?) {
        self.store = store
        self.settings = settings
        self.signaling = signaling
    }

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

    func host(_ sessionID: String) -> String? { watches[sessionID]?.host }

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
        guard let signaling = signaling(), case .ready = signaling.voiceAvailability else { return held(sessionID) }
        guard (try? await store.macOnline(watch.host)) == true else { return unreachable(sessionID) }
        let request = UUID()
        watches[sessionID]?.requests.insert(request)
        do {
            let peer = try await signaling.resolveVoicePeer(VoiceDeviceID(watch.host))
            let open = (watches[sessionID]?.opens ?? 0) > 0
            try await signaling.sendVoice(.live(signal: .watch(request: request, session: sessionID, open: open)), session: channel, to: peer)
        } catch {
            guard case .ready = signaling.voiceAvailability else { return held(sessionID) }
            unreachable(sessionID)
        }
    }

    private func held(_ sessionID: String) {
        if watches[sessionID]?.answeredAt != nil { watches[sessionID]?.answeredAt = .now }
    }

    /// 请 Mac 把这个会话亮在最前（`LiveSignal.show`），接着要拉起 UU 远程：最多等 `showWait`，发不出、中转没连上都不拦。
    /// 等的是发出去，不等 Mac 做完：App 一被 UU 顶到后台，中转连接就可能停下。记下看的是它（`AppSettings.remoteViewing`），回来时请 Mac 放回去（`comeBack`）。
    /// "亮出"与"放回"到 Mac 的先后要同人做的先后：还在请它放回的那一遍先停下，没赶上 `showWait` 的这一句也不再发，
    /// 不然迟到的那句会把刚铺满的放回去、把刚放回的又铺满。
    func show(_ sessionID: String, on host: String) async {
        returning?.cancel()
        returning = nil
        settings.remoteViewing[sessionID] = host
        guard let signaling = signaling(), case .ready = signaling.voiceAvailability else { return }
        let (sent, done) = AsyncStream<Never>.makeStream()
        let sending = Task {
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
        sending.cancel()
    }

    func comeBack() async {
        let task = returning ?? Task { await self.sendBacks() }
        returning = task
        await task.value
        if returning == task { returning = nil }
    }

    private func sendBacks() async {
        for _ in 0..<Self.returnTries {
            #if os(iOS)
            guard UIApplication.shared.applicationState == .active else { return }
            #endif
            for (sessionID, host) in settings.remoteViewing {
                let reached = await back(sessionID, on: host)
                guard !Task.isCancelled else { return }
                if reached { settings.remoteViewing[sessionID] = nil }
            }
            guard !settings.remoteViewing.isEmpty, (try? await Task.sleep(for: .seconds(1))) != nil else { return }
        }
        settings.remoteViewing = [:]
    }

    private func back(_ sessionID: String, on host: String) async -> Bool {
        guard let signaling = signaling(), case .ready = signaling.voiceAvailability else { return false }
        let request = UUID()
        backs.insert(request)
        do {
            let peer = try await signaling.resolveVoicePeer(VoiceDeviceID(host))
            try await signaling.sendVoice(.live(signal: .back(request: request, session: sessionID)), session: VoiceSessionID(UUID()), to: peer)
            try? await Task.sleep(for: Self.bounceWait)
        } catch {
            backs.remove(request)
            return false
        }
        return backs.remove(request) != nil
    }

    static let showWait = Duration.seconds(1)
    static let bounceWait = Duration.seconds(1)
    static let returnTries = 30

    private func unreachable(_ sessionID: String) {
        answers[sessionID] = nil
        offline.insert(sessionID)
    }

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
            guard case .command(let id) = header.purpose, backs.remove(id.rawValue) == nil,
                  let (sessionID, _) = watches.first(where: { $0.value.requests.contains(id.rawValue) }) else { return }
            unreachable(sessionID)
        case .availability(.ready):
            for sessionID in watches.keys { renew(sessionID) }
        default: break
        }
    }
}
