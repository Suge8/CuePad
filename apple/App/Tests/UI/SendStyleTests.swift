#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 发送钮（⌘↩）的主次只有一处规则（`Workspace.sendStyle`）：发给 Agent 会话且能一按就发时是唯一的靛青主钮；
/// 发给应用或剪贴板是次要样式（不让一次 ⌘↩ 把私人内容悄悄贴进聊天应用）；还没有可发的目标时只是选目标的菜单。
@MainActor
struct SendStyleTests {
    let app = TestApp()

    @Test func 应用与剪贴板是次要样式_没有目标或会话已结束只是菜单() {
        let workspace = Workspace(services: app.services)

        #expect(workspace.sendStyle(.app(.bundleID("com.tencent.xinWeChat"))) == .secondary)
        #expect(workspace.sendStyle(.clipboard) == .secondary)
        #expect(workspace.sendStyle(.app(.lastFrontmost)) == .menu)  // CuePad 启动后还没有别的应用到过前台
        #expect(workspace.sendStyle(.pi("gone.1", .send)) == .menu)  // 选过的会话已结束
    }

    @Test func 按钮上的字_应用写粘贴到_剪贴板写复制到() {
        let workspace = Workspace(services: app.services)

        #expect(workspace.action(for: .clipboard) == "复制到剪贴板")
        #expect(workspace.action(for: .app(.bundleID("com.tencent.xinWeChat"))).hasPrefix("粘贴到 "))
    }
}
#endif
