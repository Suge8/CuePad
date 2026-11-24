#if os(iOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor @Suite(.releasesLibraries)
struct LivePhoneFlowTests {
    let app = TestApp()
    static let mac = "mac-live"
    private let page = Asking()

    private final class Asking {
        var task: Task<Void, Never>?
    }

    private func phone(page html: String = "<html><body>手机上的页面</body></html>",
                       _ body: (Workspace, Mac, URL, SessionRoute, Page) async throws -> Void) async throws {
        let mac = Mac()
        app.services.liveSignaling = mac
        mac.answer = { [remote = app.services.liveRemote] in remote.receive($0) }
        let page = try await Page(html)
        let url = try await vacant()
        mac.allow(url)
        try await mac.openDoor(to: page.port)
        mac.pages = [url]

        try await app.services.store.recordMacPresence(host: Self.mac) { true }
        let recorder = try await app.runtimeRecorder(on: Self.mac)
        try await recorder.update(sessionID: "live", state: .settled, title: "live")
        let state = try #require(try await app.services.store.sessionState("live"))
        let workspace = Workspace(services: app.services)
        let route = SessionRoute(id: state.id, sessionID: "live")
        workspace.show(.session(route))
        self.page.task = Task { await app.services.liveRemote.watch("live", on: Self.mac) }
        do { try await body(workspace, mac, url, route, page) } catch {
            await self.page.task?.stop()
            mac.close()
            page.stop()
            throw error
        }
        await self.page.task?.stop()
        mac.close()
        page.stop()
        app.services.liveSignaling = nil
    }

    private func shown(_ preview: LivePreview, in workspace: Workspace) -> Task<Void, Never> {
        Task {
            async let watching: Void = preview.watch()
            await workspace.connectLive(preview)
            await watching
        }
    }

    @Test func Mac答有页面就出钮_点开经隧道载出Mac上的页面_收起留着_离开会话页放掉() async throws {
        try await phone { workspace, mac, url, route, _ in
            try await eventually("页头出现预览钮，指着 Mac 上的这一页") { workspace.liveButton(route.id) == .closed(url) }

            workspace.toggleLivePreview()
            #expect(workspace.showsLivePreview(route.id) && workspace.liveButton(route.id) == .open(url))
            let preview = try #require(workspace.livePreviews[route.id])
            var open = shown(preview, in: workspace)
            try await eventually("经隧道载出 Mac 上的页面") { preview.phase == .live && preview.revealed }
            #expect(try await preview.run("return document.body.innerText") as? String == "手机上的页面")
            #expect(preview.link?.state == .ready && mac.opened)
            _ = try await preview.run("document.cookie = 'who=phone; max-age=3600'")

            workspace.toggleLivePreview()
            await open.stop()
            #expect(!workspace.showsLivePreview(route.id) && workspace.liveButton(route.id) == .closed(url))
            #expect(workspace.livePreviews[route.id] === preview, "收起留着这个预览")
            try await eventually("收起就不再要隧道") { preview.link == nil && !mac.opened }

            workspace.toggleLivePreview()
            #expect(workspace.livePreviews[route.id] === preview)
            open = shown(preview, in: workspace)
            try await eventually("再点开经隧道载出") { preview.link?.state == .ready && preview.phase == .live && preview.revealed }
            #expect(try await preview.run("return document.cookie") as? String == "who=phone", "登录状态还在")

            workspace.toggleLivePreview()
            await open.stop()
            workspace.path = []
            #expect(workspace.livePreviews[route.id] == nil, "离开会话页放掉")
        }
    }

    @Test func 切到别的应用再回来_会话页还没再问_预览自己连回Mac() async throws {
        try await phone { workspace, _, _, route, _ in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            var open = shown(preview, in: workspace)
            try await eventually("页面载出") { preview.phase == .live && preview.revealed }

            await open.stop()
            await page.task?.stop()
            open = shown(preview, in: workspace)
            try await eventually("预览连回 Mac，页面还在") { preview.link?.state == .ready && preview.phase == .live && preview.revealed }
            await open.stop()
        }
    }

    @Test func 断过再通_整页重新载入一次() async throws {
        try await phone { workspace, mac, _, route, page in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("页面载出") { preview.phase == .live && preview.revealed }
            #expect(page.loaded == 1)
            _ = try await preview.run("window.before = true")

            try await mac.openDoor(to: page.port)
            app.services.liveRemote.renew("live")
            try await eventually("再通后整页重新载入") { page.loaded == 2 && preview.phase == .live && preview.revealed }
            // 服务记下第二次载入时网页视图可能还没换到新的一页（整套一起跑时碰到过）：等到换过去
            try await eventually("是新的一页") { (try? await preview.run("return window.before ?? false")) as? Bool == false }
            await quietPeriod(.seconds(2))
            #expect(page.loaded == 2, "只载一次")
            await open.stop()
        }
    }

    @Test func 连着的被网络打断_入口没变也整页重载一次() async throws {
        try await phone(page: "<html><body>手机上的页面<script>fetch('/stream')</script></body></html>") { workspace, mac, _, route, page in
            let door = try #require(mac.door)
            let network = try await Network(to: door.port)
            defer { network.stop() }
            mac.door = (door.addresses, network.port)
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("页面载出、事件流连着") { preview.phase == .live && preview.revealed && page.streaming == 1 }
            #expect(page.loaded == 1)

            network.cut()
            try await eventually("同一个入口重新连上、整页重新载入") { page.loaded == 2 && preview.phase == .live && preview.revealed }
            await quietPeriod(.seconds(2))
            #expect(page.loaded == 2, "只载一次")
            await open.stop()
        }
    }

    @Test func 服务换了端口_开着与收着时都跟到新地址() async throws {
        try await phone { workspace, mac, _, route, _ in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            var open = shown(preview, in: workspace)
            try await eventually("页面载出") { preview.phase == .live && preview.revealed }

            let moved = try await vacant()
            mac.allow(moved)
            mac.pages = [moved]
            app.services.liveRemote.renew("live")
            try await eventually("开着时跟到新端口载出") { preview.url?.port == moved.port && preview.phase == .live && preview.revealed }

            workspace.toggleLivePreview()
            await open.stop()
            let again = try await vacant()
            mac.allow(again)
            mac.pages = [again]
            app.services.liveRemote.renew("live")
            try await eventually("收着时钮已指着新地址") { workspace.liveButton(route.id) == .closed(again) }
            workspace.toggleLivePreview()
            open = shown(preview, in: workspace)
            try await eventually("再点开载的是新地址") { preview.url?.port == again.port && preview.phase == .live && preview.revealed }
            #expect(preview.address == again)
            workspace.toggleLivePreview()
            await open.stop()
        }
    }

    @Test func 手机上自己填的地址_Mac的答复变了也不换() async throws {
        try await phone { workspace, mac, url, route, _ in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("页面载出") { preview.phase == .live && preview.revealed }

            let typed = url.appending(path: "pricing")
            preview.retarget(.init(url: typed, source: .typed))
            try await eventually("载出填的那一页") { preview.url?.path() == "/pricing" && preview.phase == .live && preview.revealed }

            let other = try await vacant()
            mac.allow(other)
            mac.pages = [url, other]
            app.services.liveRemote.renew("live")
            try await eventually("手机收到变了的答复") { app.services.liveRemote.answers["live"]?.pages.count == 2 }
            await quietPeriod(.milliseconds(500))
            #expect(preview.address == typed && preview.url?.path() == "/pricing")
            await open.stop()
        }
    }

    @Test func 收着时Agent发来新地址_再点开是新地址() async throws {
        try await phone { workspace, mac, url, route, _ in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            var open = shown(preview, in: workspace)
            try await eventually("页面载出") { preview.phase == .live && preview.revealed }
            workspace.toggleLivePreview()
            await open.stop()

            let sent = url.appending(path: "pricing")
            mac.sent = .init(url: sent, found: false, at: .now)
            mac.found = [url]
            mac.pages = [sent, url]
            app.services.liveRemote.renew("live")
            try await eventually("钮指着新发来的地址") { workspace.liveButton(route.id) == .closed(sent) }

            workspace.toggleLivePreview()
            open = shown(preview, in: workspace)
            try await eventually("再点开载的是新地址") { preview.url?.path() == "/pricing" && preview.phase == .live && preview.revealed }
            #expect(preview.address == sent)
            workspace.toggleLivePreview()
            await open.stop()
        }
    }

    @Test func 点选页面上的元素_预览收回_元素挂进回复框() async throws {
        try await phone { workspace, _, _, route, _ in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("页面载出") { preview.phase == .live && preview.revealed }

            workspace.pickElement()
            try await eventually("点选开着") { preview.picking }
            try await eventually("点上了") {
                try await preview.run("const handle = window[Symbol.for('cuepad.pick')]; if (!handle) return false; handle.pick('body'); return true") as? Bool == true
            }
            try await eventually("元素挂进回复框、预览收回、回复框接过焦点") {
                app.services.settings.replyNotes(for: route.id).contains { $0.element?.selector == "body" } && !workspace.showsLivePreview(route.id)
                    && workspace.replyFocus == route.id
            }
            await open.stop()
        }
    }

    @Test func 和Mac不在同一个网络_点在Mac上操作_先请Mac亮出这个会话再拉起UU远程_回来了请它放回去_发不出也照样拉起() async throws {
        try await phone { workspace, mac, _, route, _ in
            var opened: [(url: URL, revealed: Int)] = []
            workspace.apps = ExternalApps { url in
                opened.append((url, mac.revealed.count))
                return true
            }
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            // Mac 报的地址不在手机的任何网段里（127.0.0.2 本机没有，连上去立刻失败）
            mac.door = ([.init(host: "127.0.0.2", prefix: 32)], 9)
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("说和 Mac 不在同一个网络") { preview.link?.trouble == .apart }
            #expect(preview.link?.trouble?.reachesByRemote == true)

            await workspace.viewOnMac(preview)
            #expect(opened.last?.url.path() == "/device/authorize" && mac.revealed.isEmpty, "没绑过先在 UU 里选这台 Mac，这时还不请 Mac 亮出来")
            await workspace.returnFromMac()
            #expect(mac.returned.isEmpty, "选完电脑回来不算看完回来")
            let nonce = try #require(app.services.settings.remoteBinding?.nonce)
            let other = Workspace(services: app.services)
            other.apps = workspace.apps
            await other.remoteBound(device: "enc-x", error: nil, nonce: nonce)
            #expect(mac.revealed == ["live"])
            #expect(opened.count == 2 && opened.last?.revealed == 1 && opened.last?.url.query()?.contains("anonymous_device_id=enc-x") == true, "选完接着远控，拉起前请求已发出")

            mac.bounces = 1
            await workspace.returnFromMac()
            #expect(mac.returned == ["live"] && mac.bounces == 0, "回到 CuePad：请 Mac 把铺满的预览放回去；中转退回来的那一句不算，再请一次")
            await workspace.returnFromMac()
            #expect(mac.returned == ["live"], "只请一次")

            await workspace.viewOnMac(preview)
            mac.present = false
            let returning = Task { await workspace.returnFromMac() }
            await quietPeriod(.milliseconds(300))
            mac.present = true
            await workspace.viewOnMac(preview)
            await returning.value
            await quietPeriod(.milliseconds(1500))
            #expect(mac.revealed.count == 3 && mac.returned == ["live"] && app.services.settings.remoteViewing["live"] != nil, "这一次的放回留给下一次回来")

            mac.showing = .fails
            await workspace.viewOnMac(preview)
            #expect(opened.count == 5 && opened.last?.url.query()?.contains("anonymous_device_id=enc-x") == true, "发不出也照样远控这台")

            mac.showing = .hangs
            let started = ContinuousClock.now
            await workspace.viewOnMac(preview)
            #expect(opened.count == 6 && .now - started < .seconds(2), "挂住不回的不久等")
            app.services.settings.remoteViewing = [:]
            mac.letGo()
            await open.stop()
        }
    }

    @Test func 连不上Mac的口说可能是Wi_Fi不让设备互连_手机自己没连上中转不改口_Mac走了说不在线() async throws {
        try await phone { workspace, mac, _, route, _ in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            let mine = try #require(LiveTunnel.localAddresses().first { !$0.host.contains(":") })
            mac.door = ([mine], 9)
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("说这个 Wi-Fi 可能不让设备互相连接") { preview.link?.trouble == .isolated }
            #expect(preview.phase != .live)

            mac.connected = false
            app.services.liveRemote.renew("live")
            await quietPeriod(.milliseconds(500))
            #expect(preview.link?.trouble == .isolated)
            mac.connected = true
            mac.drops = true
            app.services.liveRemote.renew("live")
            try await eventually("问到一半断的") { !mac.connected }
            await quietPeriod(.milliseconds(300))
            #expect(preview.link?.trouble == .isolated, "也不算")
            mac.connected = true

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
