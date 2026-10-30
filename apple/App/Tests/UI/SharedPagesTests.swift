import CueStore
import Foundation
import Testing
@testable import CuePad

/// 两端共用的页面状态：回收站的内容与操作、新会话从发出到认领的进度。
struct SharedPagesTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    // MARK: 回收站

    /// 永久删除走界面同一个入口（`Workspace.purge`）：项目连同它的卡一起没了，单独删的卡还在回收站。恢复见下一条。
    @Test func 回收站列出删除的项目与卡片_永久删除项目连同它的卡() async throws {
        let project = try await store.createProject(name: "旧项目", color: "#000000")
        _ = try await store.createCard(in: project.id, body: "项目里的一条")
        _ = try await store.createCard(in: project.id, body: "项目里的另一条")
        let lone = try await store.createCard(body: "单独删的\n补一句")
        try await store.trashProject(project.id)
        try await store.trashCard(lone.id)

        let summary = try await TrashSummary.read(from: store)
        #expect(summary.projects.map(\.title) == ["旧项目"] && summary.projects.map(\.detail) == ["2 条"])
        #expect(summary.cards.map(\.title) == ["单独删的"])

        Workspace(services: app.services).purge(try #require(summary.projects.first))
        let after = try await eventually(store, { try TrashSummary.read(from: $0) }) { $0.projects.isEmpty }
        #expect(after.cards.map(\.id) == [lone.id])
        #expect(try await store.project(project.id) == nil)
        #expect(try await store.cards(in: project.id).isEmpty)
    }

    /// 恢复后给一句提示写明落点、点它过去（与删除时的"已删除 · 撤销"对称）；卡片所在的项目还在回收站时落到默认项目。
    @Test func 回收站恢复后提示落点_点它过去() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let card = try await store.createCard(in: project.id, body: "项目里的一条")
        let loose = try await store.createCard(body: "没有项目的一条")
        try await store.trashCard(card.id)
        try await store.trashCard(loose.id)
        let workspace = Workspace(services: app.services)
        let summary = try await TrashSummary.read(from: store)

        func restored(_ item: TrashItem) async throws -> Workspace.Notice? {
            workspace.restore(item)
            try await eventually("workspace.notice != nil") { workspace.notice != nil }
            defer { workspace.notice = nil }
            return workspace.notice
        }
        let inProject = try await restored(try #require(summary.cards.first { $0.id == card.id }))
        #expect(inProject?.text.visible == "已恢复到 圆桌" && inProject?.link == .project(project.id))
        let home = try await restored(try #require(summary.cards.first { $0.id == loose.id }))
        #expect(home?.text.visible == "已恢复到 默认" && home?.link == .project(Project.defaultID))

        try await store.trashProject(project.id)
        let whole = try await restored(try #require(try await TrashSummary.read(from: store).projects.first))
        #expect(whole?.text.visible == "已恢复到 圆桌" && whole?.link == .project(project.id))
    }

    #if os(iOS)
    @Test func 新会话认领时_时间异常的历史仍只有一组和一份会话() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        let now = Date.now
        for (id, date) in [("future", now.addingTimeInterval(90 * 86_400)), ("today", now), ("past", now.addingTimeInterval(-90 * 86_400))] {
            try await recorder.update(sessionID: id, state: .ended, title: id, times: PiTimes(stateSince: date, busySince: nil))
        }
        let workspace = Workspace(services: app.services)
        workspace.showSessions()
        func checkList(expectNew: Bool = false) async throws {
            let list = try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, at: .always(), from: store)
            let sections = list.historyRuns.map(\.section)
            let rows = list.pinned + list.now + list.historyRuns.flatMap(\.items)
            #expect(Set(sections).count == sections.count)
            #expect(Set(rows.map(\.id)).count == rows.count)
            #expect(Set(rows.map(\.state.sessionID)).isSuperset(of: ["future", "today", "past"]))
            #expect(rows.filter { $0.state.sessionID == "new" }.count == (expectNew ? 1 : 0))
        }
        try await checkList()
        let launch = try await NewSessionInput.Start(project: project.id).launch(
            in: project, on: "mac-a", draft: ComposerDraft(text: "检查重连"), agent: .pi, model: nil, thinking: nil, services: app.services)
        try await checkList()
        try await recorder.update(sessionID: "new", state: .thinking, title: "新会话", launchToken: launch.token)
        #expect(try await launch.progress(from: store).claimed?.sessionID == "new")
        try await checkList(expectNew: true)
    }
    #endif

    // MARK: 新会话进度

    @Test func 新会话从发出到认领_失败带着原因() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let request = try await store.requestLaunch(PiLaunch(project: project.id, prompt: nil, token: "tok-1"), title: "圆桌", on: "mac-a", card: nil)
        func phase() async throws -> LaunchProgress.Phase {
            try await SessionLaunch(request: request.id, token: "tok-1").progress(from: store).phase(at: .always())
        }
        guard case .sending = try await phase() else { Issue.record("发出后应是在路上：\(try await phase())"); return }

        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { _ in }) { _, _ in .succeeded }
        try await executor.start()
        _ = try await eventually(store, { try SessionLaunch(request: request.id, token: "tok-1").progress(from: $0).phase(at: .always()) }) { $0 == .opening }
        #expect(try await phase() == .opening)

        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .thinking, title: "圆桌", launchToken: "tok-1")
        let claimed = try await SessionLaunch(request: request.id, token: "tok-1").progress(from: store)
        #expect(claimed.phase(at: .always()) == .claimed && claimed.claimed?.sessionID == "s1")
        await executor.stop()

        let refused = try await store.requestLaunch(PiLaunch(project: project.id, prompt: nil, token: "tok-2"), title: "圆桌", on: "mac-b", card: nil)
        let failing = DeliveryExecutor(store: store, hostID: "mac-b", onIssue: { _ in }) { _, _ in .failed(.verbatim("文件夹不在了")) }
        try await failing.start()
        _ = try await eventually(store, { try $0.deliveryRequest(refused.id)?.isOpen }) { $0 == false }
        await failing.stop()
        #expect(try await SessionLaunch(request: refused.id, token: "tok-2").progress(from: store).phase(at: .always()) == .failed(.reported("文件夹不在了")))
    }
}
