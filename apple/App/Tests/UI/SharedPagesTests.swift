import CueStore
import Foundation
import Testing
@testable import CuePad

/// 两端共用的页面状态：Agent 页的分页与空态、回收站的内容与操作、新会话从发出到认领的进度。
@MainActor
struct SharedPagesTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    // MARK: Agent 页

    @Test func 历史读到底才接着读下一页_换搜索词回到第一页() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        for index in 0..<45 { try await recorder.update(sessionID: "e\(index)", state: .ended, title: "e\(index)") }
        let model = AgentListModel()
        model.list = try await PiSessionList.read(text: model.query, historyLimit: model.limit, from: store)
        #expect(model.list?.loaded == PiSessionList.pageSize && model.hasMore)

        model.loadMore()
        model.list = try await PiSessionList.read(text: model.query, historyLimit: model.limit, from: store)
        #expect(model.list?.loaded == 45 && !model.hasMore)

        model.query = "e1"
        #expect(model.limit == PiSessionList.pageSize)
    }

    @Test func 列表空着时按搜索_没绑文件夹_项目内_全部说不同的话() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let model = AgentListModel()

        #expect(model.empty(filtering: nil, hasFolder: true) == .none(inProject: false))
        #expect(model.empty(filtering: project, hasFolder: true) == .none(inProject: true))
        #expect(model.empty(filtering: project, hasFolder: false) == .needsFolder(project))
        model.query = " 部署 "
        #expect(model.empty(filtering: project, hasFolder: false) == .noMatch(" 部署 "))
    }

    // MARK: 回收站

    @Test func 回收站列出删除的项目与卡片_恢复与永久删除() async throws {
        let project = try await store.createProject(name: "旧项目", color: "#000000")
        _ = try await store.createCard(in: project.id, body: "项目里的一条")
        _ = try await store.createCard(in: project.id, body: "项目里的另一条")
        let lone = try await store.createCard(in: nil, body: "单独删的\n补一句")
        try await store.trashProject(project.id)
        try await store.trashCard(lone.id)

        let summary = try await TrashSummary.read(from: store)

        #expect(summary.count == 2 && !summary.isEmpty)
        #expect(summary.projects.map(\.title) == ["旧项目"] && summary.projects.first?.detail.contains("2") == true)
        #expect(summary.cards.map(\.title) == [CardText(lone.body).label])
        try await summary.cards[0].restore(store)
        try await summary.projects[0].purge(store)
        #expect(try await TrashSummary.read(from: store).isEmpty)
        #expect(try await store.card(lone.id)?.deletedAt == nil)
    }

    /// 恢复后给一句提示写明落点、点它过去（与删除时的"已删除 · 撤销"对称）；卡片所在的项目还在回收站时落到未分类。
    @Test func 回收站恢复后提示落点_点它过去() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let card = try await store.createCard(in: project.id, body: "项目里的一条")
        let loose = try await store.createCard(in: nil, body: "没有项目的一条")
        try await store.trashCard(card.id)
        try await store.trashCard(loose.id)
        let workspace = Workspace(services: app.services)
        let summary = try await TrashSummary.read(from: store)

        func restored(_ item: TrashItem) async -> Workspace.Notice? {
            workspace.restore(item)
            await eventually { workspace.notice != nil }
            defer { workspace.notice = nil }
            return workspace.notice
        }
        let inProject = await restored(try #require(summary.cards.first { $0.id == card.id }))
        #expect(inProject?.text.visible == "已恢复到 圆桌" && inProject?.link == .project(project.id))
        let unfiled = await restored(try #require(summary.cards.first { $0.id == loose.id }))
        #expect(unfiled?.text.visible == "已恢复到 未分类" && unfiled?.link == .unfiled)

        try await store.trashProject(project.id)
        let whole = await restored(try #require(try await TrashSummary.read(from: store).projects.first))
        #expect(whole?.text.visible == "已恢复到 圆桌" && whole?.link == .project(project.id))
    }

    // MARK: 新会话进度

    @Test func 新会话从发出到认领_失败带着原因() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let request = try await store.requestLaunch(PiLaunch(project: project.id, prompt: nil, token: "tok-1"), title: "圆桌", on: "mac-a", card: nil)
        func phase() async throws -> LaunchProgress.Phase {
            try await LaunchProgress.read(request: request.id, token: "tok-1", from: store).phase
        }
        func wait(until done: (LaunchProgress.Phase) -> Bool) async throws {
            for _ in 0..<3000 where !done(try await phase()) { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard case .sending = try await phase() else { Issue.record("发出后应是在路上：\(try await phase())"); return }

        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _ in .succeeded }
        try await executor.start()
        try await wait { $0 == .opening }
        #expect(try await phase() == .opening)

        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .thinking, title: "圆桌", launchToken: "tok-1")
        let claimed = try await LaunchProgress.read(request: request.id, token: "tok-1", from: store)
        #expect(claimed.phase == .claimed && claimed.claimed?.sessionID == "s1")
        await executor.stop()

        let refused = try await store.requestLaunch(PiLaunch(project: project.id, prompt: nil, token: "tok-2"), title: "圆桌", on: "mac-b", card: nil)
        let failing = DeliveryExecutor(store: store, hostID: "mac-b", onIssue: { _ in }) { _ in .failed("文件夹不在了") }
        try await failing.start()
        for _ in 0..<3000 where try await store.deliveryRequest(refused.id)?.isOpen != false { try await Task.sleep(for: .milliseconds(10)) }
        await failing.stop()
        #expect(try await LaunchProgress.read(request: refused.id, token: "tok-2", from: store).phase == .failed("文件夹不在了"))
    }
}
