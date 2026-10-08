#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 的导航与手机一致：侧栏点项目、Agent、会话，任务与灵感都在右侧内容区整页切换，不再弹浮窗；
/// 有返回与前进（⌘[ ⌘]），返回回到原来那一页；新的跳转清掉前进；开着灵感纸页时返回先收起纸页。
@MainActor
struct MacNavigationTests {
    let rig = TestApp()

    @Test func 打开会话后返回回到原来那页_前进又回到会话() {
        let workspace = Workspace(services: rig.services)
        let project = UUID()
        workspace.show(.project(project))

        workspace.openSession("s1")
        #expect(workspace.openedSession == "s1")
        #expect(workspace.page == .project(project))

        workspace.goBack()
        #expect(workspace.openedSession == nil)
        #expect(workspace.page == .project(project))

        workspace.goForward()
        #expect(workspace.openedSession == "s1")
    }

    @Test func 从项目页到Agent页再返回_回到项目页() {
        let workspace = Workspace(services: rig.services)
        let project = UUID()
        workspace.show(.project(project))
        workspace.show(.agent)
        #expect(workspace.page == .agent)

        workspace.goBack()
        #expect(workspace.page == .project(project))
        #expect(workspace.canGoForward)
    }

    @Test func 新的跳转清掉前进() {
        let workspace = Workspace(services: rig.services)
        workspace.show(.inbox)
        workspace.openSession("s1")
        workspace.goBack()
        workspace.openSession("s2")
        #expect(!workspace.canGoForward)
        workspace.goBack()
        #expect(workspace.openedSession == nil)
        #expect(workspace.page == .inbox)
    }

    @Test func 开着灵感纸页时返回先收起纸页() {
        let workspace = Workspace(services: rig.services)
        workspace.show(.inbox)
        workspace.openSession("s1")
        workspace.openCard = UUID()

        workspace.goBack()
        #expect(workspace.openCard == nil)
        #expect(workspace.openedSession == "s1")
    }
}
#endif
