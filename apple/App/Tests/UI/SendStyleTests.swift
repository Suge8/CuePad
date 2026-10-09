#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 上只有提示词发给 Agent：目标只有本项目的 Agent 会话（`Workspace.agentTarget`）。选过的会话已结束时照样写它"已结束"、不悄悄换掉；
/// 本项目一个会话都没有时没有目标，发送钮只是选会话的菜单。
@MainActor
struct SendStyleTests {
    let app = TestApp()

    @Test func 没有会话时没有目标_选过的会话已结束时照样是它() {
        let workspace = Workspace(services: app.services)
        #expect(workspace.agentTarget(for: nil) == nil)

        workspace.sendChoice = AgentTarget(session: "gone.1")
        // 本次运行里没见过这个会话（不在桥上也不在已结束里）：不当目标
        #expect(workspace.agentTarget(for: nil) == nil)
    }

    @Test func 菜单与读屏的说法写明发给哪个Agent会话() {
        let workspace = Workspace(services: app.services)
        #expect(workspace.action(for: AgentTarget(session: "x.1")) == "发给 Agent 会话「Agent」")
    }
}
#endif
