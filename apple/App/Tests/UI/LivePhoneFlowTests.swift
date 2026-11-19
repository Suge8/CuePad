#if os(iOS)
import CryptoKit
import CueStore
import CueTestSupport
import Foundation
import Network
import Testing
@testable import CuePad

/// 手机这头看 Mac 会话的活预览，从工作区的方法走（页头那颗钮、铺满的那一页调的就是它们）。
/// Mac 是替身：中转上收到"看着"就答这个会话的页面，开着预览时另给隧道的入口；隧道口是真的（`LiveTunnel.Server`），后面是本进程里的一个网页服务。
@MainActor @Suite(.releasesLibraries)
struct LivePhoneFlowTests {
    let app = TestApp()
    static let mac = "mac-live"

    /// 替身 Mac：答的规则同 `Workspace.receiveLive`（只答它这台上的会话、开着才给入口），放行同 `admitLive`（票据对、端口是这个会话的）。
    final class Mac: VoiceSignaling {
        let local = VoiceEndpoint(device: .init("phone-live"), lease: UUID())
        let endpoint = VoiceEndpoint(device: .init(LivePhoneFlowTests.mac), lease: UUID())
        let key = SymmetricKey(size: .bits256)
        let ticket = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var pages: [URL] = []
        var door: (addresses: [LiveTunnel.Address], port: UInt16)?
        var present = true
        var answer: (VoiceRelayEvent) -> Void = { _ in }
        var voiceAvailability: VoiceRelayAvailability { .ready(endpoint: local) }
        var voiceEvents: AsyncStream<VoiceRelayEvent> { AsyncStream { _ in } }
        var liveTunnelKey: SymmetricKey? { key }

        func resolveVoicePeer(_ device: VoiceDeviceID) async throws -> VoiceEndpoint {
            guard present, device == endpoint.device else { throw VoiceSignalError.peerUnavailable }
            return endpoint
        }

        func sendVoice(_ payload: VoiceSignalPayload, session: VoiceSessionID, to recipient: VoiceEndpoint) async throws {
            guard case .live(.watch(let request, let sessionID, let open)) = payload else { return }
            let door = open ? door.map { LiveSignal.Door(addresses: $0.addresses, port: $0.port, ticket: ticket) } : nil
            let reply = LiveSignal.pages(request: request, session: sessionID, pages: pages, serving: pages, door: door)
            let header = VoiceSignalHeader(version: VoiceSignalFormat.version, sender: endpoint, recipient: local, session: session, sequence: 1,
                                           expiresAtMilliseconds: Int64(Date.now.timeIntervalSince1970 * 1000) + 30_000, purpose: VoiceSignalPayload.live(signal: reply).purpose)
            let answer = answer
            Task { answer(.received(.init(header: header, payload: .live(signal: reply)))) }
        }
    }

    /// 本进程里的网页服务：什么请求都回同一页。
    /// 模拟器与 Mac 共用回环，直连也连得上它：所以 Mac 报给手机的是另一个没人听的口，只有隧道那头把它接到这里（`phone`），页面载得出就是走了隧道。
    final class Page {
        let listener: NWListener
        let port: UInt16

        init(_ body: String) async throws {
            listener = try NWListener(using: .tcp)
            listener.newConnectionHandler = { connection in
                connection.start(queue: LiveTunnel.queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { _, _, _, _ in
                    let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
                    connection.send(content: Data((head + body).utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                }
            }
            let listener = listener
            port = try await withCheckedThrowingContinuation { ready in
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: ready.resume(returning: listener.port!.rawValue)
                    case .failed(let error): ready.resume(throwing: error)
                    default: break
                    }
                }
                listener.start(queue: LiveTunnel.queue)
            }
        }
    }

    /// 一个此刻没人听的口。
    private func vacant() async throws -> UInt16 {
        let page = try await Page("")
        page.listener.cancel()
        return page.port
    }

    /// 手机开着这个会话页、Mac 替身接在中转上、在线；Mac 的隧道口放行这一页的端口。跑完 `body` 拆掉。
    private func phone(_ body: (Workspace, Mac, URL, SessionRoute) async throws -> Void) async throws {
        let mac = Mac()
        app.services.liveSignaling = mac
        mac.answer = { [remote = app.services.liveRemote] in remote.receive($0) }
        let page = try await Page("<html><body>手机上的页面</body></html>")
        let ticket = mac.ticket, port = page.port, shown = try await vacant()
        let server = try LiveTunnel.Server(key: mac.key) { request in
            guard request.ticket == ticket else { return .ticket }
            if request.port == 0 { return .probe }
            return request.port == shown ? .open(host: "127.0.0.1", port: port) : .refused
        }
        mac.door = ([.init(host: "127.0.0.1", prefix: 8)], try await server.start())
        let url = try #require(URL(string: "http://localhost:\(shown)"))
        mac.pages = [url]

        try await app.services.store.recordMacPresence(host: Self.mac) { true }
        let recorder = try await app.runtimeRecorder(on: Self.mac)
        try await recorder.update(sessionID: "live", state: .settled, title: "live")
        let state = try #require(try await app.services.store.sessionState("live"))
        let workspace = Workspace(services: app.services)
        let route = SessionRoute(id: state.id, sessionID: "live")
        workspace.show(.session(route))
        // 会话页看得见时问（`SessionPage` 的 task）
        let watching = Task { await app.services.liveRemote.watch("live", on: Self.mac) }
        do { try await body(workspace, mac, url, route) } catch {
            await watching.stop()
            server.cancel()
            page.listener.cancel()
            throw error
        }
        await watching.stop()
        server.cancel()
        page.listener.cancel()
        app.services.liveSignaling = nil
    }

    /// 打开的那一页（铺满的那一页挂上时它的两个 task：探页面在不在、连 Mac）。
    private func shown(_ preview: LivePreview, in workspace: Workspace) -> Task<Void, Never> {
        Task {
            async let watching: Void = preview.watch()
            await workspace.connectLive(preview)
            await watching
        }
    }

    @Test func Mac答有页面就出钮_点开经隧道载出Mac上的页面_收起就放掉() async throws {
        try await phone { workspace, _, url, route in
            try await eventually("页头出现预览钮，指着 Mac 上的这一页") { workspace.liveButton(route.id) == .closed(url) }

            workspace.toggleLivePreview()
            #expect(workspace.showsLivePreview(route.id) && workspace.liveButton(route.id) == .open(url))
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("经隧道载出 Mac 上的页面") { preview.phase == .live && preview.revealed }
            #expect(try await preview.run("return document.body.innerText") as? String == "手机上的页面")
            #expect(preview.link?.state == .ready)

            workspace.toggleLivePreview()
            await open.stop()
            #expect(!workspace.showsLivePreview(route.id) && workspace.livePreviews[route.id] == nil)
            #expect(workspace.liveButton(route.id) == .closed(url))
        }
    }

    @Test func 连不上Mac的口说可能是Wi_Fi不让设备互连_Mac走了说不在线() async throws {
        try await phone { workspace, mac, _, route in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            // Mac 报的是手机自己所在网段里一个不通的口：同网段却连不上
            let mine = try #require(LiveTunnel.localAddresses().first { !$0.host.contains(":") })
            mac.door = ([mine], 9)
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("说这个 Wi-Fi 可能不让设备互相连接") { preview.link?.trouble == .isolated }
            #expect(preview.phase != .live)

            mac.present = false
            let left = ContinuousClock.now
            app.services.liveRemote.receive(.peerClosed(endpoint: mac.endpoint, reason: .disconnected))
            try await eventually("说 Mac 不在线") { preview.link?.trouble == .offline }
            #expect(.now - left < .seconds(2), "中转一说 Mac 走了就改口，不等下一次续问")
            await open.stop()
        }
    }
}
#endif
