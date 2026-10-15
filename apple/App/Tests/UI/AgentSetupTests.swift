#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 首次打开的接入：列出这台 Mac 上检测到的 Agent、默认全选、一键接入；接入过或看过面板的不再弹。
struct AgentSetupTests {
    let app = TestApp()

    /// 像启动时那样检测完全部 Agent，再请工作区决定弹不弹（`AppDelegate` 同一个调用）。
    private func launch() async -> Workspace {
        let workspace = Workspace(services: app.services)
        await app.services.agents.redetect()
        await workspace.offerAgentSetup()
        return workspace
    }

    @Test func 首次打开_列出检测到的Agent_一键全接入_之后不再弹() async throws {
        try app.install(.pi)
        try app.install(.claudeCode)

        let first = await launch()
        #expect(first.showsAgentSetup)
        let agents = app.services.agents
        #expect(agents.connectable == [.pi, .claudeCode])

        #expect(await agents.install(agents.connectable).isEmpty)
        #expect(agents.status(.pi)?.isConnected == true && agents.status(.claudeCode)?.isConnected == true)
        #expect(agents.connectable.isEmpty)

        app.relaunch()
        #expect(await launch().showsAgentSetup == false)
    }

    @Test func 看过不接_下次不再弹() async throws {
        try app.install(.claudeCode)
        #expect(await launch().showsAgentSetup)

        app.relaunch()
        #expect(await launch().showsAgentSetup == false)
    }

    @Test func 已经接入过一家_不弹() async throws {
        try await app.connect(.claudeCode)
        try app.install(.pi)

        #expect(await launch().showsAgentSetup == false)
    }

    @Test func 一家都没检测到_不弹() async throws {
        #expect(await launch().showsAgentSetup == false)
    }
}
#endif
