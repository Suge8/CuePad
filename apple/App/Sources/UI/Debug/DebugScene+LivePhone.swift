#if os(iOS) && DEBUG
import CryptoKit
import CueStore
import Foundation

extension DebugScene {
    /// 扮会话所在的那台 Mac：中转上收到"看着"就答这一页（同 `Workspace.receiveLive`，开着才给入口），隧道口是真的，放行到本机回环上的同一个端口。
    /// 模拟器与 Mac 共用网络：入口报的是 Mac 的局域网地址，手机走的是真机上那条路（局域网地址 → 隧道 → 回环）。
    private final class LiveMac: VoiceSignaling {
        let local = VoiceEndpoint(device: .init("debug-phone"), lease: UUID())
        let endpoint: VoiceEndpoint
        let key = SymmetricKey(size: .bits256)
        let ticket = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let pages: [URL]
        var door: LiveSignal.Door?
        let answer: (VoiceRelayEvent) -> Void
        var voiceAvailability: VoiceRelayAvailability { .ready(endpoint: local) }
        var voiceEvents: AsyncStream<VoiceRelayEvent> { AsyncStream { _ in } }
        var liveTunnelKey: SymmetricKey? { key }

        init(host: String, pages: [URL], answer: @escaping (VoiceRelayEvent) -> Void) {
            endpoint = VoiceEndpoint(device: .init(host), lease: UUID())
            self.pages = pages
            self.answer = answer
        }

        func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint { endpoint }

        func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws {
            guard case .live(.watch(let request, let sessionID, let open)) = payload else { return }
            let reply = LiveSignal.pages(request: request, session: sessionID, pages: pages, serving: pages, sent: nil, door: open ? door : nil, ports: nil)
            let header = VoiceSignalHeader(version: VoiceSignalFormat.version, sender: endpoint, recipient: local, session: session, sequence: 1,
                                           expiresAtMilliseconds: Int64(Date.now.timeIntervalSince1970 * 1000) + 30_000, purpose: VoiceSignalPayload.live(signal: reply).purpose)
            answer(.received(.init(header: header, payload: .live(signal: reply))))
        }
    }

    private static var liveMac: (mac: LiveMac, server: LiveTunnel.Server)?

    /// `-CuePadLivePreview <地址>`：开着的会话页由替身 Mac 答这一页，钮出来后打开它，载完才算就绪。
    static func openLivePhoneIfAsked(_ workspace: Workspace) async {
        guard let address = args.layoutOpts.livePreview, let url = LiveAddress.url(from: address) else { return }
        let services = workspace.services
        guard let page = workspace.shownSessions.first, let sessionID = page.sessionID else { abandon("活预览", Unmet("没有开着的会话页")) }
        await running("活预览的替身 Mac") {
            guard let state = try await services.store.sessionState(sessionID) else { throw Unmet("会话 \(sessionID) 不在库里") }
            _ = try await services.store.recordMacPresence(host: state.hostID) { true }
            let mac = LiveMac(host: state.hostID, pages: [url]) { [remote = services.liveRemote] in remote.receive($0) }
            let ticket = mac.ticket
            let server = try LiveTunnel.Server(key: mac.key) { request in
                guard request.ticket == ticket else { return .ticket }
                return request.port == 0 ? .probe : .open(host: "127.0.0.1", port: request.port)
            }
            let port = try await server.start()
            // 127.0.0.2 本机没有、不在手机的任何网段里：连上去立刻失败，说不在同一个网络（`LiveLink.reach`）
            let addresses = args.layoutOpts.liveApart ? [.init(host: "127.0.0.2", prefix: 32)] : LiveTunnel.localAddresses().filter { !$0.host.contains(":") }
            mac.door = LiveSignal.Door(addresses: addresses.isEmpty ? [.init(host: "127.0.0.1", prefix: 8)] : addresses, port: port, ticket: ticket)
            liveMac = (mac, server)
            services.liveSignaling = mac
            services.liveRemote.renew(sessionID)
        }
        holdingReady("活预览载入") {
            while workspace.liveButton(page.id) == nil { await Task.wait(for: .milliseconds(50)) }
            workspace.toggleLivePreview()
            if args.layoutOpts.liveViewport == "window" { workspace.toggleLiveFill() }
            while workspace.livePreviews[page.id].map({ args.layoutOpts.liveApart ? $0.link?.trouble != .apart : !($0.phase == .live && $0.revealed) }) ?? true {
                await Task.wait(for: .milliseconds(100))
            }
            await Task.wait(for: .milliseconds(600))
        }
    }

    /// `-CuePadLiveCycle YES`：收起、打开，一遍遍来回，看长开与收回。
    static func cycleLivePhoneIfAsked(_ workspace: Workspace) async {
        guard args.layoutOpts.liveCycle, args.layoutOpts.livePreview != nil else { return }
        while await Task.wait(for: .milliseconds(2500)) { workspace.toggleLivePreview() }
    }
}
#endif
