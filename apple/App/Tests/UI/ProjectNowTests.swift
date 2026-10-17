import CueStore
import Foundation
import Testing
@testable import CuePad

/// 项目的"此刻"一行（书架大卡与行、iPad、Mac 侧栏共用）：每个项目只挑一件最该知道的事，按优先取第一个——
/// 等你确认（它在问什么）→ 出错（原因）→ Agent 在跑（在做什么）→ 有新回复（回复第一句）→ 进行中的任务 → 项目介绍；都没有就没有。
struct ProjectNowTests {
    let project = UUID()

    private func item(
        _ id: String, _ state: PiWorkState, detail: String? = nil, question: String? = nil, reply: String? = nil, project: UUID? = nil
    ) -> PiSessionListItem {
        let at = Date(timeIntervalSince1970: 100)
        return PiSessionListItem(state: PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: project ?? self.project, state: .known(state), detail: detail,
            folder: nil, lastPrompt: "做一下", lastReply: reply, question: question.map { PiQuestion(promptID: nil, kind: .text, text: $0) },
            notify: nil, stateSince: at, busySince: at, createdAt: at, modifiedAt: at))
    }

    /// 回复第一句只在你没看过时算"有新回复"：测试里 notes 没看过，其余停着的都看过。
    private func shown(_ item: PiSessionListItem) -> PiShown {
        PiShown(item.state, delivery: item.delivery, unread: item.state.sessionID == "notes", at: .always())
    }

    private func now(_ sessions: [PiSessionListItem], task: String? = "补重连用例", intro: String? = "多 Agent 调度本月可上线") -> ProjectNow? {
        ProjectNow.pick(sessions, shown: shown, task: task, intro: intro)
    }

    @Test func 按优先只挑一件() {
        let asking = item("rename", .waitingForUser, question: "新分支叫什么？\n随便起一个")
        let broken = item("billing", .error, detail: "模型拒绝了请求（400）")
        let busy = item("atlas", .tool, detail: "bash · pnpm test")
        let unread = item("notes", .settled, reply: "整理好了。三件待办。")
        let seen = item("old", .settled, reply: "早就看过了。")

        #expect(now([busy, broken, asking, unread])?.text == "新分支叫什么？")
        #expect(now([busy, unread, broken])?.text == "模型拒绝了请求（400）")
        #expect(now([unread, busy])?.text == "运行 pnpm test")
        #expect(now([seen, unread])?.text == "整理好了。")
        #expect(now([seen])?.text == "补重连用例")
        #expect(now([seen], task: nil)?.text == "多 Agent 调度本月可上线")
        #expect(now([seen], task: nil, intro: nil) == nil)
    }

    /// 会话没有回答（模型拒绝、中途被停）：最后那句可能是 Cue 发进去的，近况不写它，只写状态（会话名已经说了是什么事）。
    @Test func 没有回答时不写最后那句() {
        let silent = item("notes", .settled)
        #expect(now([silent])?.text == shown(silent).presence)
    }

}

/// 没送到的话在"此刻"与会话行是同一个判定（`AppSettings.shown`）：你看过那个会话之前写没送到的原因，
/// 看过以后不再写（会话行只留小标记），"此刻"按其余档往下取——在线的会话停着就轮到进行中的任务，已结束的轮到项目介绍。
struct ProjectNowSeenTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 没送到的原因_看过那个会话以后不再占此刻() async throws {
        let project = try await store.createProject(name: "装修", color: "#000000")
        try await store.updateProject(project.id) { $0.intro = "三家报价" }
        let recorder = PiStateRecorder(store: store, hostID: "mac-fail")
        try await recorder.update(sessionID: "relay", state: .settled, title: "relay", projectID: project.id)
        try await recorder.update(sessionID: "quote", state: .settled, title: "quote", projectID: project.id)
        try await recorder.end(sessionID: "quote")
        let task = ProjectNow.InProgress(id: UUID(), title: "比价")
        var lost: [UUID] = []
        for name in ["relay", "quote"] {
            lost.append(try await store.requestDelivery("备份一下", to: SendTarget(kind: .piSession, name: name, ref: name), on: "mac-fail", mode: .send).id)
        }
        let executor = DeliveryExecutor(store: store, hostID: "mac-fail", onIssue: { _ in }) { _ in .failed("Pi 已经退出") }
        try await executor.start()
        for id in lost {
            _ = try await eventually(store, { try $0.deliveryRequest(id)?.isOpen }) { $0 == false }
        }
        await executor.stop()
        func now(_ tasks: [ProjectNow.InProgress] = []) async throws -> String? {
            let current = try await store.piSessionPage(.current).items
            return ProjectNow.byProject(
                [project.id], sessions: current, tasks: [project.id: tasks], intros: [project.id: "三家报价"],
                shown: Workspace(services: app.services).shown)[project.id]?.text
        }
        func state(_ id: String) async throws -> PiSessionState {
            try #require(try await store.piSessionPage(PiSessionQuery(limit: 10)).items.first { $0.state.sessionID == id }?.state)
        }

        #expect(try await now([task]) == "Pi 已经退出")

        app.services.settings.markSeen(try await state("relay"), at: .now.addingTimeInterval(1))
        #expect(try await now([task]) == "Pi 已经退出")  // quote 还没看过

        app.services.settings.markSeen(try await state("quote"), at: .now.addingTimeInterval(1))
        #expect(try await now([task]) == "比价")
        #expect(try await now() == "三家报价")
    }
}

#if os(iOS)
/// 侧栏的"此刻"看得到发给已结束会话的话：发出后在唤醒、没能送达时，项目写的是它，不回落到任务或介绍；
/// iPhone 书架不写会话（会话在 Agent 标签），同一个项目写介绍。
struct ProjectNowShelfTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 发给已结束会话的话_在侧栏的此刻里_书架只写介绍() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.updateProject(project.id) { $0.intro = "多 Agent 调度本月可上线" }
        let recorder = PiStateRecorder(store: store, hostID: "mac")
        try await recorder.update(sessionID: "atlas", state: .settled, title: "atlas", projectID: project.id)
        try await recorder.end(sessionID: "atlas")
        try await store.requestDelivery("再跑一遍", to: SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), on: "mac")

        let shelf = try await ShelfData.read(from: store)
        let sessions = try await LiveSessions.Page.read(from: store).items

        let projects = try await ProjectCatalog.read(from: store).projects
        let workspace = Workspace(services: app.services)
        #expect(ProjectNow.byProject(projects, sessions: sessions, tasks: shelf.leading) { workspace.shown($0) }[project.id]?.text == "正在唤醒 Agent")
        #expect(shelf.now(projects: projects)[project.id]?.text == "多 Agent 调度本月可上线")
    }

    @Test func 改一条普通灵感不改变书架读到的数据() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("补重连用例", in: project.id)
        try await store.setStatus(task.id, .inProgress)
        let idea = try await store.createCard(in: project.id, body: "想法")
        let before = try await ShelfData.read(from: store)
        #expect(before.active.map(\.id) == [task.id])

        try await store.updateCard(idea.id) { $0.body = "想法，补一句" }
        #expect(try await ShelfData.read(from: store) == before)  // 灵感数在项目目录里，书架数据不含，不跟着重画
    }
}
#endif
