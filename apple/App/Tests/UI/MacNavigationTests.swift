#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 的导航与手机一致：侧栏点项目、Agent、会话，任务与灵感都在右侧内容区整页切换，不再弹浮窗；
/// 有返回与前进（⌘[ ⌘]），返回回到原来那一页、原来的滚动位置；新的跳转清掉前进；开着灵感纸页时返回先收起纸页。
/// 任务整页与手机的任务浮窗一样能"带上"相关灵感与资料交给 Agent。
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

    @Test func 返回与前进回到那一页离开时的滚动位置_重新点开从顶上开始() {
        let workspace = Workspace(services: rig.services)
        let project = UUID()
        workspace.show(.project(project))
        workspace.scrolled(to: 420)
        workspace.show(.agent)
        workspace.scrolled(to: 90)

        workspace.goBack()
        #expect(workspace.takeRestoredScroll() == 420)
        workspace.goForward()
        #expect(workspace.takeRestoredScroll() == 90)

        workspace.show(.project(project))
        #expect(workspace.takeRestoredScroll() == nil)
    }

    @Test func 任务整页带上相关灵感交给Agent_发送记录记着带上了哪些() async throws {
        let workspace = Workspace(services: rig.services)
        let store = rig.services.store
        let task = try await store.createTask("修乱序", in: nil)
        let idea = try await store.createCard(in: nil, body: "日志在 logs/0918.txt")
        try await workspace.attach(idea.id, to: task.id)
        let detail = try await TaskDetail.read(task.id, from: store)

        let sent = await workspace.handOff(task.id, body: "修乱序", detail: detail, bundle: TaskBundleChoice(), via: .clipboard)

        #expect(sent)
        let record = try #require(try await store.sendRecords().first)
        #expect(record.partIDs == [idea.id])
        #expect(record.content == TaskBundle.text(task: "修乱序", parts: detail.related))
    }
}
#endif
