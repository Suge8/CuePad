import CueStore
import Foundation
import Testing
@testable import CuePad

/// 在 Mac 上操作（`Workspace+Remote`）：替身记下拉起了哪些链接（只用替身，不真去拉起 UU 远程）。
/// 第一次连一台 Mac 先去 UU 里选电脑，回跳后记下并直接远控，以后一点即连；没装 UU 时提示去 App Store；
/// 几台 Mac 时先选一台，之后连上次那台；回跳的 nonce 对不上的不认；远控照官方示例带回跳，UU 回了失败就说原因、标识失效的请用户重新选。
@MainActor
struct MacRemoteTests {
    private final class Apps {
        var installed = true
        var opened: [URL] = []
        var external: ExternalApps {
            ExternalApps { [self] url in
                guard installed || url.scheme != "uuremote" else { return false }
                opened.append(url)
                return true
            }
        }
    }

    private func query(_ url: URL?, _ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }

    @Test func 第一次先在UU里选电脑_回跳后直接远控_以后一点即连() async throws {
        let app = TestApp(), apps = Apps()
        let workspace = Workspace(services: app.services)
        workspace.apps = apps.external

        await workspace.operate(on: "studio")
        let authorize = try #require(apps.opened.last)
        #expect(authorize.host() == "external" && authorize.path() == "/device/authorize")
        #expect(query(authorize, "callback") == "cuepad://uu-bound")
        let nonce = try #require(query(authorize, "nonce"))

        // 回跳先经链接认出来（同系统打开 cuepad://uu-bound?…）；nonce 对不上的不认
        await workspace.remoteBound(device: "enc-x", error: nil, nonce: "other")
        #expect(apps.opened.count == 1)
        let link = try #require(DeepLink(url: URL(string: "cuepad://uu-bound?anonymous_device_id=a%2Bb%2Fc%3D%3D&nonce=\(nonce)")!))
        guard case .remoteBound(let device, let error, let back) = link else { Issue.record("认不出回跳"); return }
        await workspace.remoteBound(device: device, error: error, nonce: back)
        // 标识里的 + / = 照转义发回 UU（按表单规则读也不会把 + 当空格），回跳照官方示例带上、认得出是哪台
        #expect(apps.opened.last?.query(percentEncoded: true) == "anonymous_device_id=a%2Bb%2Fc%3D%3D&window_type=0&callback=cuepad%3A%2F%2Fuu-control%3Fhost%3Dstudio")

        await workspace.operate(on: "studio")
        #expect(apps.opened.count == 3 && query(apps.opened.last, "anonymous_device_id") == "a+b/c==")

        // 重新选择：再去 UU 里选一次
        await workspace.rebindMac("studio")
        #expect(apps.opened.last?.path() == "/device/authorize")
    }

    @Test func 远控回了失败说原因_标识失效的忘掉并重新选择() async throws {
        let app = TestApp(), apps = Apps()
        let workspace = Workspace(services: app.services)
        workspace.apps = apps.external
        app.services.settings.remoteDevices = ["studio": "enc-old"]

        // UU 在发来的回跳后面接上结果（保留原有的 host，文档 3.5）
        let back = try #require(query(MacRemote.control("enc-old", host: "studio"), "callback"))
        func callback(_ result: String) -> DeepLink? { URL(string: back + result).flatMap(DeepLink.init(url:)) }
        #expect(callback("&status=success") == nil)
        workspace.open(try #require(callback("&status=failure&reason=user_cancel")))
        #expect(workspace.notice == nil)

        workspace.open(try #require(callback("&status=failure&reason=busy")))
        #expect(workspace.notice?.isError == true && workspace.notice?.action == nil)
        #expect(app.services.settings.remoteDevices["studio"] == "enc-old")

        workspace.open(try #require(callback("&status=failure&reason=device_not_found")))
        #expect(app.services.settings.remoteDevices["studio"] == nil)
        try await #require(workspace.notice?.action).run()
        #expect(apps.opened.last?.path() == "/device/authorize")
    }

    @Test func 没装UU时提示去AppStore_绑定失败说原因_取消的不说() async throws {
        let app = TestApp(), apps = Apps()
        apps.installed = false
        let workspace = Workspace(services: app.services)
        workspace.apps = apps.external

        await workspace.operate(on: "studio")
        #expect(apps.opened.isEmpty)
        let notice = try #require(workspace.notice)
        #expect(notice.text.parts.joined().contains("UU 远程"))
        try await #require(notice.action).run()
        #expect(apps.opened == [MacRemote.appStore])

        apps.installed = true
        workspace.notice = nil
        await workspace.operate(on: "studio")
        let nonce = try #require(query(apps.opened.last, "nonce"))
        await workspace.remoteBound(device: nil, error: "user_cancel", nonce: nonce)
        #expect(workspace.notice == nil)
        await workspace.operate(on: "studio")
        let again = try #require(query(apps.opened.last, "nonce"))
        await workspace.remoteBound(device: nil, error: "no_device", nonce: again)
        #expect(workspace.notice?.isError == true)
    }

    @Test func 几台Mac时先选一台_之后连上次那台() async throws {
        let app = TestApp(), apps = Apps()
        let workspace = Workspace(services: app.services)
        workspace.apps = apps.external
        let store = app.services.store
        let before = try await store.allMacAgents().count
        for (host, name) in [("studio", "Mac Studio"), ("air", "MacBook Air")] {
            try await store.recordMacAgents(host: host, name: name, [])
        }

        let choices = try #require(await workspace.operateMac())
        #expect(choices.count == before + 2 && apps.opened.isEmpty)
        await workspace.operate(on: "air")
        #expect(await workspace.operateMac() == nil)
        #expect(apps.opened.count == 2 && apps.opened.allSatisfy { $0.path() == "/device/authorize" })
        #expect(app.services.settings.remoteLastHost == "air")
    }
}
