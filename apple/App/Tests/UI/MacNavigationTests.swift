#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 的导航没有历史：侧栏点哪就是哪，会话也是一页；Agent 整页是会话的主页，会话页往上一层回到它（不论从哪进来）；
/// 开着灵感纸页时往上一层先收起纸页；项目、未分类、归档、回收站与 Agent 整页没有上一层。
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

    @Test func 会话页往上一层回到Agent整页_不论从哪进来() {
        let workspace = Workspace(services: rig.services)
        workspace.show(.project(UUID()))
        workspace.show(.session("s1"))
        #expect(workspace.up == .agentList)

        workspace.goUp()
        #expect(workspace.page == .agent)
        #expect(workspace.up == nil)
    }

    @Test func 开着纸页时往上一层先收起纸页() {
        let workspace = Workspace(services: rig.services)
        workspace.show(.session("s1"))
        workspace.openCard = UUID()
        #expect(workspace.up == .closePaper)

        workspace.goUp()
        #expect(workspace.openCard == nil)
        #expect(workspace.page == .session("s1"))
    }

    @Test func 根页没有上一层() {
        let workspace = Workspace(services: rig.services)
        for page in [Workspace.Page.project(UUID()), .inbox, .archive, .trash, .agent] {
            workspace.show(page)
            #expect(workspace.up == nil, "\(page)")
        }
    }
}
#endif
