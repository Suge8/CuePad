import CueStore
import Foundation
#if os(iOS)
import UIKit
#endif

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
    /// 在请 Mac 放回去的那一遍（`comeBack`）；写进连接、还在等中转退不退回来的那几句（`back`）。
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

    /// 人回到 CuePad 了：用 UU 远程看过的会话（`AppSettings.remoteViewing`），请那台 Mac 把铺满的预览放回去（`LiveSignal.back`）。
    /// 刚回来时中转多半还在重连，没发到的每秒再试；试 `returnTries` 次还不行就不再管（Mac 的预览栏上有"放回右半"）。
    /// 不在活动状态（被推送在后台叫醒、又切走了）不发：他可能还在 UU 里看着。iPad 几个窗口各调一次，合成一遍。
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
                // 又去看了（`show`）：这一遍作废，记着的留给下一次回来
                guard !Task.isCancelled else { return }
                if reached { settings.remoteViewing[sessionID] = nil }
            }
            guard !settings.remoteViewing.isEmpty, (try? await Task.sleep(for: .seconds(1))) != nil else { return }
        }
        settings.remoteViewing = [:]
    }

    /// 发到了返回 true；中转没连上、那台 Mac 不在、中转转不过去退了回来（它刚断、换了租约，`receive` 的 rejected）返回 false。
    private func back(_ sessionID: String, on host: String) async -> Bool {
        guard let signaling = signaling(), case .ready = signaling.voiceAvailability else { return false }
        let request = UUID()
        backs.insert(request)
        do {
            let peer = try await signaling.resolveVoicePeer(VoiceDeviceID(host))
            try await signaling.sendVoice(.live(signal: .back(request: request, session: sessionID)), session: VoiceSessionID(UUID()), to: peer)
            // 写进连接不等于转到了：Mac 不答这一句，转不过去时中转会退回来，等它一个往返
            try? await Task.sleep(for: Self.bounceWait)
        } catch {
            backs.remove(request)
            return false
        }
        return backs.remove(request) != nil
    }

    /// 平常一问一发约两个中转往返；再长就不等了，钮点下去不能没反应。
    static let showWait = Duration.seconds(1)
    static let bounceWait = Duration.seconds(1)
    static let returnTries = 30

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
            guard case .command(let id) = header.purpose, backs.remove(id.rawValue) == nil,
                  let (sessionID, _) = watches.first(where: { $0.value.requests.contains(id.rawValue) }) else { return }
            unreachable(sessionID)
        case .availability(.ready):
            for sessionID in watches.keys { renew(sessionID) }
        default: break
        }
    }
}
