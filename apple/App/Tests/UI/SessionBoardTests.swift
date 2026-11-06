import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 会话进看板：不归没做完的事的活会话与任务支持同一组操作，第一次拖到已完成、置顶、改名时当场建任务绑上，从没这样用过的不留卡；
/// 名字只有一个事实源——任务标题，标题为空时随会话名变；只读跟读的会话能拖状态，不能发话与改名。
struct SessionBoardTests {
    let rig = TestApp()
    var services: AppServices { rig.services }
    var store: CueStore { services.store }
    /// 会话所在的那台 Mac（手机上跑也一样：投送请求写给它）。
    static let mac = "mac-a"

    /// 一个歇着的会话（默认终端里的 Pi，只记了一次状态）。
    private func session(
        _ id: String, title: String, agent: AgentKind = .pi, hosted: Bool = false
    ) async throws -> PiSessionState {
        let recorder = try await rig.runtimeRecorder(on: Self.mac)
        try await recorder.update(
            sessionID: id, state: .settled, title: title, hosted: hosted, agent: agent)
        return try #require(try await store.piSessions(sessionIDs: [id])[id]?.state)
    }

    /// 会话在这件任务完成之后有了新状态：时刻显式排在完成之后（收起按时刻严格先后判定，不靠真实时钟走过一毫秒）。
    /// `by` 为 0 时与完成同一毫秒。
    private func moves(_ sessionID: String, after task: UUID, by seconds: TimeInterval = 1) async throws {
        let done = try #require(try await store.card(task)?.completedAt)
        let at = done.addingTimeInterval(seconds)
        try await rig.runtimeRecorder(on: Self.mac).update(sessionID: sessionID, state: .thinking, times: PiTimes(stateSince: at, busySince: at))
    }

    private func tasks() async throws -> [Card] { try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks) }

    /// 看板上这件任务写的名字与会话行写的名字（同各自的视图：`BoardTaskCard`、`PiSessionRow`）。
    private func names(_ task: UUID, _ sessionID: String) async throws -> [String] {
        let board = try await TaskBoard.read(from: store)
        let item = try #require(board.item(task))
        let row = try #require(try await store.piSessions(sessionIDs: [sessionID])[sessionID])
        return [item.task.title(session: item.agent?.shownTitle(at: services.speech)), row.name(at: services.speech)]
    }

    @Test func 无主会话拖到已完成_当场建卡绑上_任务完成_终端里的会话不结束只收起() async throws {
        let terminal = try await session("s1", title: "修登录")
        let hosted = try await session("s2", title: "补测试", hosted: true)
        let workspace = Workspace(services: services)
        let before = try await TaskBoard.read(from: store)
        #expect(Set(before.advancing.map(\.id)) == ["session/s1", "session/s2"])
        #expect(try await tasks().isEmpty, "没当任务用过的会话不留卡")

        try await workspace.finish(PiSessionListItem(state: terminal))
        try await workspace.finish(PiSessionListItem(state: hosted))
        #expect(workspace.sessionAsk == nil, "歇着的会话不问")

        let made = try await tasks()
        #expect(made.count == 2 && made.allSatisfy { $0.status == .done && $0.heading.isEmpty })
        #expect(Set(made.compactMap(\.piSessionID)) == ["s1", "s2"])
        let board = try await TaskBoard.read(from: store)
        #expect(board.advancing.isEmpty, "两张会话卡都随完成收起")
        #expect(Set(board.done.compactMap(\.agent?.state.sessionID)) == ["s1", "s2"])
        for card in made {
            let name = card.piSessionID == "s1" ? "修登录" : "补测试"
            #expect(try await names(card.id, card.piSessionID!) == [name, name], "标题为空的写会话名")
        }
        #expect(try await store.deliveryRequests(toSession: "s1").isEmpty, "终端里你开的会话不替你结束")
        #expect(try await store.deliveryRequests(toSession: "s2").map(\.mode) == [.known(.end)], "托管的照做完的规则结束")

        // 收起的会话再有动静才回到看板：与完成同一毫秒的不算，严格晚于完成的才算
        let s1 = try #require(made.first { $0.piSessionID == "s1" }).id
        try await moves("s1", after: s1, by: 0)
        #expect(try await TaskBoard.read(from: store).advancing.isEmpty, "同一毫秒分不出先后，按没动过算")
        try await moves("s1", after: s1)
        #expect(try await TaskBoard.read(from: store).advancing.map(\.id) == ["session/s1"])
    }

    @Test func 完成后归档或项目进回收站_活会话没卡代表_照常回推进中() async throws {
        let workspace = Workspace(services: services)
        let project = try await store.createProject(name: "回收", color: "#000000")
        let archived = try await session("s1", title: "修登录")
        try await rig.runtimeRecorder(on: Self.mac).update(sessionID: "s2", state: .settled, title: "补测试", projectID: project.id)
        let trashed = try #require(try await store.piSessions(sessionIDs: ["s2"])["s2"]?.state)
        try await workspace.finish(PiSessionListItem(state: archived))
        try await workspace.finish(PiSessionListItem(state: trashed))
        #expect(try await TaskBoard.read(from: store).advancing.isEmpty, "完成时随卡收起")

        let made = try await tasks()
        let first = try #require(made.first { $0.piSessionID == "s1" })
        try await workspace.archive(first.id)
        #expect(try await TaskBoard.read(from: store).advancing.map(\.id) == ["session/s1"], "卡归档了，会话没有东西代表，回推进中")

        #expect(made.first { $0.piSessionID == "s2" }?.projectID == project.id, "建在会话所在的项目里")
        try await store.trashProject(project.id)
        #expect(Set(try await TaskBoard.read(from: store).advancing.map(\.id)) == ["session/s1", "session/s2"])
    }

    @Test func 等你里的无主会话点完成_先问一句_答应了才建卡完成() async throws {
        // 在问你只认宿主在线时报的（`runtimeUntil`）
        try await rig.runtimeRecorder(on: Self.mac).update(sessionID: "q1", state: .waitingForUser, title: "要不要推送")
        let board = try await TaskBoard.read(from: store)
        let held = try #require(board.held.first { $0.session.sessionID == "q1" })
        #expect(held.item == nil && board.advancing.isEmpty)

        // 菜单里的完成与拖到已完成同一条路（`finish`）：在等你的会话先问，不先建卡
        let workspace = Workspace(services: services)
        try await workspace.finish(PiSessionListItem(state: held.session))
        #expect(workspace.sessionAsk == .complete(held.session))
        #expect(try await tasks().isEmpty, "问过之前什么都不留")

        try await workspace.confirmFinish(held.session)
        let task = try #require(try await tasks().first)
        #expect(task.status == .done && task.piSessionID == "q1")
    }

    @Test func 置顶无主会话_建一件进行中的置顶任务_再点不再多建() async throws {
        let live = try await session("s1", title: "修登录")
        let workspace = Workspace(services: services)
        try await workspace.pin(live)
        try await workspace.pin(live)
        let made = try await tasks()
        #expect(made.count == 1)
        let task = try #require(made.first)
        #expect(task.isPinned && task.status == .inProgress && task.piSessionID == "s1" && task.parentID == nil)
        let board = try await TaskBoard.read(from: store)
        #expect(board.advancing.map(\.id) == ["task/\(task.id)"], "会话卡换成它的任务卡")
    }

    @Test func 改名_看板与会话行同名_并让Agent跟着改() async throws {
        let live = try await session("s1", title: "修登录")
        let workspace = Workspace(services: services)
        try await workspace.rename(live, to: "登录页白屏", adopts: true)
        let task = try #require(try await tasks().first)
        #expect(task.heading == "登录页白屏" && task.piSessionID == "s1")
        #expect(try await names(task.id, "s1") == ["登录页白屏", "登录页白屏"])
        #expect(try await store.deliveryRequests(toSession: "s1").compactMap(\.config?.name) == ["登录页白屏"])

        // 在任务正文里改标题：离开编辑时会话跟着改名
        try await store.updateCard(task.id) { $0.body = "登录页白屏（Safari）\n先查缓存" }
        workspace.leaveEditing(task.id, flush: nil, heading: "登录页白屏")
        try await eventually("改名请求发出") {
            try await store.deliveryRequests(toSession: "s1").compactMap(\.config?.name) == ["登录页白屏", "登录页白屏（Safari）"]
        }
        #expect(try await names(task.id, "s1") == ["登录页白屏（Safari）", "登录页白屏（Safari）"])

        // 没绑任务的会话在看板外改名：只让 Agent 改，不建卡
        let other = try await session("s2", title: "随便问问")
        try await workspace.rename(other, to: "问问部署", adopts: false)
        #expect(try await tasks().count == 1)
        #expect(try await store.deliveryRequests(toSession: "s2").compactMap(\.config?.name) == ["问问部署"])
    }

    @Test func 做完的旧任务还绑着_会话回到看板再改名_当场建新任务_旧任务名字不动() async throws {
        let live = try await session("s1", title: "修登录")
        let workspace = Workspace(services: services)
        try await workspace.rename(live, to: "登录页白屏", adopts: true)
        let old = try #require(try await tasks().first)
        try await workspace.complete(old.id)
        try await moves("s1", after: old.id)
        let back = try #require(try await TaskBoard.read(from: store).advancing.first { $0.loose?.state.sessionID == "s1" }?.loose?.state)

        try await workspace.rename(back, to: "注册页白屏", adopts: true)
        let made = try await tasks()
        #expect(made.count == 2)
        let fresh = try #require(made.first { $0.id != old.id })
        #expect(fresh.heading == "注册页白屏" && fresh.piSessionID == "s1" && fresh.completedAt == nil)
        #expect(try await store.card(old.id)?.heading == "登录页白屏")
        #expect(try await names(fresh.id, "s1") == ["注册页白屏", "注册页白屏"], "会话行写正在用它的那件")
    }

    @Test func 任务标题为空_随会话改名变_改过后以任务为准() async throws {
        let live = try await session("s1", title: "修登录")
        let workspace = Workspace(services: services)
        try await workspace.pin(live)
        let task = try #require(try await tasks().first)
        #expect(try await names(task.id, "s1") == ["修登录", "修登录"])

        let recorder = try await rig.runtimeRecorder(on: Self.mac)
        try await recorder.update(sessionID: "s1", state: .settled, title: "修登录与注册")
        #expect(try await names(task.id, "s1") == ["修登录与注册", "修登录与注册"])

        try await store.updateCard(task.id) { $0.body = "注册页" }
        try await recorder.update(sessionID: "s1", state: .settled, title: "别的名字")
        #expect(try await names(task.id, "s1") == ["注册页", "注册页"])
    }

    @Test func 只读会话_能拖状态_没有发话与改名() async throws {
        let grok = try await session("g1", title: "看日志", agent: .grok)
        let workspace = Workspace(services: services)
        #expect(grok.speakBlocked != nil, "只能在终端里说话")
        #expect(SessionActions.rename(grok, in: workspace) == nil && SessionActions.rename(grok, adopts: true, in: workspace) == nil)

        try await workspace.finish(PiSessionListItem(state: grok))
        let task = try #require(try await tasks().first)
        #expect(task.status == .done && task.piSessionID == "g1")
        // 改任务标题只改 CuePad 里的名字，不向它发改名
        try await store.updateCard(task.id) { $0.body = "查崩溃日志" }
        try await workspace.pushName(of: task.id)
        #expect(try await store.deliveryRequests(toSession: "g1").isEmpty)
        #expect(try await names(task.id, "g1") == ["查崩溃日志", "查崩溃日志"])
    }
}
