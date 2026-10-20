#if os(macOS)
import CueStore
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 首次打开的接入面板：一处接入检测到的 Agent 并在这台 Mac 上启用 Cue，之后对 Cue 说的话直接交给它；
/// 一家都没装时也弹（给装法），装好回来就能接；看过不接的、Cue 已启用的不再弹。
@MainActor
struct SetupTests {
    let app = TestApp()

    /// 像启动时那样请工作区决定弹不弹（`AppDelegate` 同一个调用），再像面板打开时那样检测全部 Agent。
    private func launch() async -> Workspace {
        let workspace = Workspace(services: app.services)
        workspace.offerSetup()
        await app.services.agents.redetect()
        return workspace
    }

    @Test func 首次打开_一键接入检测到的Agent并启用Cue_接着对Cue说的话交给它() async throws {
        try app.install(.pi)
        try app.install(.claudeCode)

        let first = await launch()
        #expect(first.showsSetup)
        let agents = app.services.agents
        #expect(agents.connectable == [.pi, .claudeCode])

        #expect(await first.setUp(connecting: agents.connectable, enablingCue: true).isEmpty)
        #expect(agents.status(.pi)?.isConnected == true && agents.status(.claudeCode)?.isConnected == true)
        #expect(try await app.services.store.cueProfile()?.hostID == TestApp.hostID)
        #expect(first.page == .cue)

        app.relaunch()
        let next = await launch()
        #expect(!next.showsSetup)
        next.cue.draft = ComposerDraft(text: "整理发布说明")
        await next.sayToCue(from: Bindable(next.cue).draft)?.value  // 输入框的发送：没启用时这句会记成灵感
        #expect(try await app.services.store.cueMessages().map(\.text) == ["整理发布说明"])
    }

    @Test func 一家都没装_也弹_装好回来就能接入并启用() async throws {
        let workspace = await launch()
        #expect(workspace.showsSetup)
        let agents = app.services.agents
        #expect(agents.connectable.isEmpty)

        try app.install(.pi)
        await agents.redetect()  // 回到 App 时面板重新检测
        #expect(agents.connectable == [.pi])
        #expect(await workspace.setUp(connecting: agents.connectable, enablingCue: true).isEmpty)
        #expect(try await app.services.store.cueProfile()?.enabledAt != nil)
    }

    @Test func 看过不接_下次不再弹() async throws {
        try app.install(.claudeCode)
        #expect(await launch().showsSetup)

        app.relaunch()
        #expect(await launch().showsSetup == false)
    }

    @Test func Cue已启用_不弹() async throws {
        try app.install(.pi)
        _ = try await app.services.store.updateCueProfile { profile in
            profile.hostID = "mac-cue"
            profile.enabledAt = .now
        }
        #expect(await launch().showsSetup == false)
    }
}
#endif
