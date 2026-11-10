import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct TaskCountTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func 各处写的任务数与列出的行是同一批顶层任务_任务页按状态跨项目分组() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000").id
        let release = try await store.createTask("上线", in: project)
        let backup = try await store.createTask("备份", under: release.id)
        let publish = try await store.createTask("发布", under: release.id)
        try await store.setStatus(backup.id, .inProgress)
        try await store.setStatus(publish.id, .done)
        let fix = try await store.createTask("修重连", in: project)
        try await store.setStatus(fix.id, .done)
        try await clockTick()  // 完成时间存到毫秒：同一毫秒里做完的两件分不出先后
        let shipped = try await store.createTask("发版", in: project)
        try await store.setStatus(shipped.id, .done)
        let closed = try await store.createTask("收尾", in: project)
        let reopened = try await store.createTask("补文档", under: closed.id)
        try await store.setStatus(closed.id, .done)
        try await store.setStatus(reopened.id, .todo)  // 上级跟着不再算做完
        let archived = try await store.createTask("旧的", in: project)
        _ = try await store.createTask("旧的子任务", under: archived.id)
        try await store.archive(archived.id)
        let stranded = try await store.createTask("上级归档了", in: project)
        let orphan = try await store.createTask("孤儿", under: stranded.id)
        try await store.archive(stranded.id)
        try await store.unarchive(orphan.id)
        let gone = try await store.createTask("删了的", in: project)
        try await store.trashCard(gone.id)

        let catalog = try await ProjectCatalog.read(from: store)
        let page = try await ProjectPageData.read(project, from: store)
        let board = try await TaskBoard.read(from: store)

        let open = [release.id, closed.id, orphan.id]
        #expect(Set(page.tasks.roots) == Set(open))
        #expect(catalog.openTasks[project] == open.count)
        #expect(Set(board.todo.map(\.id)) == [closed.id, orphan.id])
        #expect(board.advancing.compactMap(\.item?.id) == [release.id])
        let done = [fix.id, shipped.id]
        #expect(board.done.map(\.id) == [shipped.id, fix.id] && page.taskCounts.done == done.count)  // 做完按完成时间排，最近的在前
    }

    #if os(macOS)
    @Test func 看板_拖到推进中就是开始_Cue问它不挪列_拖到做完就是做完() async throws {
        try await rig.offersPi()
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/tmp/roundtable", for: project.id)
        let task = try await store.createTask("修发言乱序", in: project.id)
        let other = try await store.createTask("补重连用例", in: project.id)
        func board() async throws -> TaskBoard { try await TaskBoard.read(from: store) }
        func expectCountsMatchCue(_ board: TaskBoard) async throws {
            let cue = CueNow(try await CueDigest.read(from: store), at: .always(), local: CueNow.Local(waiting: nil, here: nil))
            let asks = try await store.cueMessagesWaitingForYou().count
            #expect(board.count(.advancing) == cue.advancing && board.count(.waiting) == cue.needsYou - asks)
        }
        #expect(try await Set(board().todo.map(\.id)) == [task.id, other.id])

        workspace.handOff(task)
        let launch = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil }
        let token = try #require(launch?.launch?.token)
        try await (rig.runtimeRecorder(on: TestApp.hostID)).update(sessionID: "s1", state: .thinking, title: "修发言乱序", launchToken: token)
        var columns = try await board()
        #expect(columns.advancing.map(\.item?.id) == [task.id] && columns.todo.map(\.id) == [other.id])
        try await expectCountsMatchCue(columns)

        let ask = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送发言顺序的修复"), task: task.id)
        _ = try await store.addCueMessage(.cue, text: "要删旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/legacy"))
        columns = try await board()
        #expect(columns.advancing.map(\.item?.id) == [task.id])
        try await expectCountsMatchCue(columns)

        try await workspace.services.answerCueQuestion(ask.id, CueAsk.once)
        #expect(try await board().advancing.map(\.item?.id) == [task.id])
        try await workspace.complete(task.id)
        columns = try await board()
        #expect(columns.done.map(\.id) == [task.id] && columns.advancing.isEmpty, "会话随做完的事收起")
        try await expectCountsMatchCue(columns)

        _ = try await store.addCueMessage(.cue, text: "要删分支吗？", ask: try CueAsking(.delete, action: "删掉修发言乱序的分支"), task: task.id)
        columns = try await board()
        #expect(columns.done.map(\.id) == [task.id])
        try await expectCountsMatchCue(columns)
    }
    #endif

    @Test func 会话结束任务仍推进中_看板计数同口径_执行集合独立() async throws {
        let card = try await store.createTask("开 U 卡")
        let bitget = try await store.createTask("bitget", under: card.id)
        _ = try await store.createTask("KYC", under: card.id)
        let recorder = try await rig.runtimeRecorder(on: "mac-a")
        try await recorder.update(sessionID: "kyc", state: .settled, title: "bitget")
        try await store.bindSession("kyc", to: bitget.id)
        try await recorder.update(sessionID: "kyc", state: .ended)
        let live = try await store.createTask("修登录")
        try await recorder.update(sessionID: "login", state: .thinking, title: "修登录")
        try await store.bindSession("login", to: live.id)
        try await recorder.update(sessionID: "term", state: .settled, title: "终端里的")
        func inEnvelope() async throws -> Int { try await store.cueBoard().active.count }  // 信封的"在做 N 件"数的就是它

        var board = try await TaskBoard.read(from: store)
        #expect(Set(board.advancing.map(\.id)) == ["task/\(card.id.uuidString)", "task/\(live.id.uuidString)", "session/term"])
        #expect(board.todo.isEmpty)
        #expect(try await CueDigest.read(from: store).advancing == 3)
        #expect(try await inEnvelope() == 2)

        try await recorder.update(sessionID: "kyc", state: .thinking)
        board = try await TaskBoard.read(from: store)
        #expect(Set(board.advancing.map(\.id)) == ["task/\(card.id.uuidString)", "task/\(live.id.uuidString)", "session/term"] && board.todo.isEmpty)
        #expect(try await inEnvelope() == 3)
    }
}
