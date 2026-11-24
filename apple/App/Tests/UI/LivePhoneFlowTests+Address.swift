#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

extension LivePhoneFlowTests {
    @Test func 手机上自己填的地址_Mac的答复变了也不换_放行的端口变了不重载() async throws {
        try await phone { workspace, mac, url, route, _ in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("页面载出") { preview.phase == .live && preview.revealed }

            let typed = url.appending(path: "pricing")
            preview.retarget(.init(url: typed, source: .typed))
            try await eventually("载出填的那一页") { preview.url?.path() == "/pricing" && preview.phase == .live && preview.revealed }
            _ = try await preview.run("window.before = true")

            let other = try await vacant()
            mac.allow(other)
            mac.pages = [url, other]
            app.services.liveRemote.renew("live")
            try await eventually("手机收到变了的答复") { app.services.liveRemote.answers["live"]?.pages.count == 2 }
            await quietPeriod(.milliseconds(500))
            #expect(preview.address == typed && preview.url?.path() == "/pricing")
            #expect((try? await preview.run("return window.before ?? false")) as? Bool == true, "放行的端口变了不重连、不重载")
            await open.stop()
        }
    }

    @Test func 头一回点开_开的是Mac现在给的页面_不是Mac上已被顶掉的发来的() async throws {
        try await phone { workspace, mac, url, route, _ in
            mac.sent = .init(url: url.appending(path: "gone"), found: false, at: .now)
            app.services.liveRemote.renew("live")
            try await eventually("钮指着Mac现在给的") { workspace.liveButton(route.id) == .closed(url) }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            let open = shown(preview, in: workspace)
            try await eventually("载出Mac现在给的") { preview.phase == .live && preview.revealed }
            #expect(preview.address == url)
            workspace.toggleLivePreview()
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

    @Test func 开着看自己填的地址时Agent发来新地址_先留着_收起再点开是发来的() async throws {
        try await phone { workspace, mac, url, route, _ in
            try await eventually("页头出现预览钮") { workspace.liveButton(route.id) != nil }
            workspace.toggleLivePreview()
            let preview = try #require(workspace.livePreviews[route.id])
            var open = shown(preview, in: workspace)
            try await eventually("页面载出") { preview.phase == .live && preview.revealed }
            let typed = url.appending(path: "typed")
            preview.retarget(.init(url: typed, source: .typed))

            let sent = url.appending(path: "pricing")
            mac.sent = .init(url: sent, found: false, at: .now)
            mac.pages = [sent, url]
            app.services.liveRemote.renew("live")
            try await eventually("手机收到发来的") { app.services.liveRemote.answers["live"]?.sent?.url == sent }
            await quietPeriod(.milliseconds(500))
            #expect(preview.address == typed)

            workspace.toggleLivePreview()
            await open.stop()
            workspace.toggleLivePreview()
            open = shown(preview, in: workspace)
            try await eventually("再点开载的是发来的") { preview.address == sent && preview.phase == .live && preview.revealed }
            workspace.toggleLivePreview()
            await open.stop()
        }
    }
}
#endif
