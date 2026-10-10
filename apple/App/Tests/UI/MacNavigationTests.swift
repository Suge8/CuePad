#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 的导航没有历史、也没有上一层：侧栏点哪就是哪，会话也是一页。
@MainActor
struct MacNavigationTests {
    let rig = TestApp()

    @Test func 侧栏点哪就是哪_会话也是一页() {
        let workspace = Workspace(services: rig.services)
        let project = UUID()
        workspace.show(.project(project))
        workspace.show(.session("s1"))
        #expect(workspace.page == .session("s1"))

        workspace.show(.agent)
        #expect(workspace.page == .agent)
        workspace.show(.project(project))
        #expect(workspace.page == .project(project))
    }

}
#endif
