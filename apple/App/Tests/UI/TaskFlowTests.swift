import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务优先的主动线，按用户走的路写：灵感挂成提示词 → 交给 Agent → 它回复 → 全部回复后完成并归档；中途撤销；整理任务的层级；
/// 各处写的任务数是同一批。规则单测（行的状态怎么推、任务树怎么算）都从这些动作里走一遍，不单独测。
struct TaskFlowTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }
    private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

    // MARK: 灵感走完全程

    @Test func 灵感挂成提示词_交给Agent_已回复_完成并归档() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let first = try await store.createCard(in: project.id, body: "日志在 logs/0918.txt")
        let second = try await store.createCard(in: project.id, body: "再改排序")
        let workspace = Workspace(services: rig.services)

        // 挂到新建的任务（建在灵感所在的项目），再挑一条灵感挂上来，排在最后
        try await workspace.attachToNewTask(first.id, title: "修乱序")
        let task = try #require(try await store.tasks(.todo).flatMap(\.tasks).first { $0.title == "修乱序" })
        #expect(task.projectID == project.id && workspace.notice?.text == "已成为任务的提示词")
        try await workspace.attach(second.id, to: task.id)
        let third = try await store.createCard(body: "补用例", under: task.id)
        #expect(try await store.children(of: task.id).map(\.id) == [first.id, second.id, third.id])
        #expect(try await store.cards(in: project.id).isEmpty)
        #expect(try await tally(task).text == "3 条提示词")
        #expect(try await primary(task) == first.id)

        // 交给 Agent：任务进行中并关联会话；它做完一轮是已回复，下一条成了那页唯一靛青的"交给 Agent"
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        #expect(try await state(of: first, in: task) == "unsent")
        try await store.recordSend(first.body, to: atlas, card: first.id)
        try await enter(.thinking, recorder)
        #expect(try await state(of: first, in: task) == "working atlas")
        #expect(try await action(of: first, in: task) == "watch atlas")
        let started = try #require(try await store.card(task.id))
        #expect(started.status == .inProgress && started.piSessionID == "s1")
        try await answer(1, recorder)
        #expect(try await state(of: first, in: task) == "replied atlas")
        #expect(try await action(of: first, in: task) == "handAgain")
        #expect(try await tally(task).text?.visible == "3 条提示词 · 1 已回复")
        #expect(try await primary(task) == second.id)

        // 同一个会话连着交：前面的已回复不因后面又交了一条、会话又在忙而倒退
        try await store.recordSend(second.body, to: atlas, card: second.id)
        try await enter(.thinking, recorder)
        try await answer(2, recorder)
        try await store.recordSend(third.body, to: atlas, card: third.id)
        try await enter(.thinking, recorder)
        #expect(try await replied(task) == [true, true, false])
        // 手机重发还在路上：又是在处理，不算已回复
        let resend = try await store.requestDelivery("先看日志", to: atlas, on: "mac-a", card: first.id)
        #expect(try await state(of: first, in: task) == "working atlas")
        #expect(try await replied(task) == [false, true, false])

        // 全部回复后行尾出现"完成"，任务不自动完成；用户勾选，提示里给归档
        try await answer(3, recorder)
        try await store.deleteDelivery(resend.id)
        #expect(try await tally(task).suggestsDone(task))
        #expect(try await store.card(task.id)?.status == .inProgress)
        try await workspace.toggle(task.id)
        #expect(workspace.notice?.text == "已完成")
        let archive = try #require(workspace.notice?.action)
        #expect(archive.title == "归档")
        try await archive.run()
        #expect(try await store.card(task.id)?.archivedAt != nil)
    }

    @Test func 会话没回复就结束了_提示词是会话已结束_不算全部已回复() async throws {
        let task = try await store.createTask("修乱序", in: nil)
        let prompt = try await store.createCard(body: "先复现", under: task.id)
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await store.recordSend(prompt.body, to: atlas, card: prompt.id)
        try await enter(.tool, recorder)
        try await enter(.waitingForUser, recorder)
        #expect(try await action(of: prompt, in: task) == "watch atlas")  // Agent 在处理：只给看会话
        try await recorder.end(sessionID: "s1")

        #expect(try await state(of: prompt, in: task) == "ended atlas")
        #expect(try await action(of: prompt, in: task) == "handAgain")
        #expect(try await tally(task).text == "1 条提示词")
        #expect(!(try await tally(task).suggestsDone(try #require(try await store.card(task.id)))))
    }

    // MARK: 撤销与批量

    @Test func 设为任务_删除_挂成提示词_都能撤销_勾选以最新状态为准() async throws {
        let workspace = Workspace(services: rig.services)
        let body = "上线前检查\n把 changelog 过一遍\n看下崩溃率"
        let multi = try await store.createCard(in: nil, body: body)
        try await workspace.setTodo(multi.id, true)  // 多行：第一行是任务，其余成了它的提示词
        #expect(workspace.notice?.text == "已设为任务")
        #expect(try await store.children(of: multi.id).count == 1)
        try await #require(workspace.notice?.action).run()
        #expect(try await store.cards(in: nil).map(\.body) == [body])
        #expect(try await store.card(multi.id)?.isTask == false)

        let idea = try await store.createCard(in: nil, body: "续费域名")
        try await workspace.trash(idea.id)
        #expect(workspace.notice?.text == "已删除")
        #expect(try await store.trashedCards().map(\.id) == [idea.id])
        try await #require(workspace.notice?.action).run()
        #expect(try await store.trashedCards().isEmpty)

        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let task = try await store.createTask("修乱序", in: project.id)
        let moved = try await store.createCard(in: project.id, body: "日志")
        let before = try await store.cards(in: project.id).map(\.id)
        try await workspace.attach(moved.id, TaskMove(slot: .under(task.id), after: nil))
        try await #require(workspace.notice?.action).run()
        #expect(try await store.children(of: task.id).isEmpty)
        #expect(try await store.cards(in: project.id).map(\.id) == before)

        let stale = try await store.createTask("续费域名", in: nil)
        try await workspace.toggle(stale.id)
        try await workspace.toggle(stale.id)  // 手里的副本已过时：切换以 Store 当前状态为准
        #expect(try await store.card(stale.id)?.status == .todo)

        #expect(try await workspace.addTasks(fromSelection: "- 写发布说明\n\n- 更新截图", in: project.id) == 2)
        #expect(try await store.tasks(.todo).flatMap(\.tasks).filter { $0.projectID == project.id }.map(\.body).prefix(2) == ["写发布说明", "更新截图"])
    }

    // MARK: 数字处处一致

    @Test func 各处写的任务数与列出的行是同一批顶层任务_任务页按状态跨项目分组() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000").id
        let release = try await store.createTask("上线", in: project)
        let backup = try await store.createTask("备份", under: release.id)
        let publish = try await store.createTask("发布", under: release.id)
        try await store.setStatus(backup.id, .inProgress)
        try await store.setStatus(publish.id, .done)
        let fix = try await store.createTask("修重连", in: project)
        try await store.setStatus(fix.id, .done)
        let closed = try await store.createTask("收尾", in: project)
        let reopened = try await store.createTask("补文档", under: closed.id)
        try await store.setStatus(closed.id, .done)
        try await store.setStatus(reopened.id, .todo)
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

        let open = [release.id, reopened.id, orphan.id]
        #expect(Set(page.tasks.roots) == Set(open))
        #expect(catalog.openTasks[project] == open.count && board.counts.open == open.count)
        #expect(board.inProgress.count + board.todo.count == open.count)
        let done = [fix.id, closed.id]
        #expect(Set(board.done.map(\.id)) == Set(done) && board.counts.done == done.count)
        #expect(page.taskCounts == board.counts)
        #expect(board.done.first?.task.id == closed.id)  // 最近完成按完成时间排，不按项目分组
    }

    @Test func 书架正在推进先列Agent要你处理与正在干活的_再按最近开始_只列顶层() async throws {
        let recorder = PiStateRecorder(store: store, hostID: "mac")
        try await recorder.update(sessionID: "s1", state: .tool, detail: "bash · pnpm test", title: "atlas")
        try await recorder.update(sessionID: "s2", state: .waitingForUser, title: "deploy")
        let oldest = try await store.createTask("最早开始", in: nil)
        try await store.setStatus(oldest.id, .inProgress)
        let step = try await store.createTask("子任务", under: oldest.id)
        try await store.setStatus(step.id, .inProgress)
        let working = try await store.createTask("在干活", in: nil)
        try await store.recordSend(working.body, to: SendTarget(kind: .piSession, name: "atlas", ref: "s1"), card: working.id)
        let asking = try await store.createTask("等你确认", in: nil)
        try await store.recordSend(asking.body, to: SendTarget(kind: .piSession, name: "deploy", ref: "s2"), card: asking.id)
        let newest = try await store.createTask("最近开始", in: nil)
        try await store.setStatus(newest.id, .inProgress)

        let active = try await TaskBoard.active(limit: 3, from: store)

        #expect(active.rows.map(\.task.id) == [asking.id, working.id, newest.id] && active.more == 1)
        #expect(active.rows.first { $0.task.id == working.id }?.session?.state == .known(.tool))
        #expect(try await TaskBoard.counts(from: store).inProgress == 4)  // 标题上的"4 进行中"：顶层，不含子任务
    }

    // MARK: 整理任务的层级

    /// a（a1（a1x）、a2）、b。界面给出的每一次移动，Store 都接受。
    @Test func 整理任务_缩进_反缩进_拖放_界面给出的移动Store都接受() async throws {
        let a = try await store.createTask("a", in: nil)
        let b = try await store.createTask("b", in: nil)
        try await store.moveCard(a.id, to: .top(project: nil), after: nil)
        let a1 = try await store.createTask("a1", under: a.id)
        let a1x = try await store.createTask("a1x", under: a1.id)
        let a2 = try await store.createTask("a2", under: a.id)
        func tree() async throws -> TaskTree { TaskTree(try await store.tasks(.todo).flatMap(\.tasks)) }
        func apply(_ move: TaskMove?, _ id: UUID) async throws {
            let move = try #require(move)
            try await store.moveCard(id, to: move.slot, after: move.after)
        }

        let folded = try await tree().rows(toggled: [])
        #expect(folded.map(\.id) == [a.id, a1.id, a2.id, b.id] && folded.map(\.depth) == [0, 1, 1, 0])  // 第三级默认折起
        #expect(try await tree().rows(toggled: [a1.id]).map(\.id) == [a.id, a1.id, a1x.id, a2.id, b.id])

        // 缩进成为上一个同级的最后一个子任务；没有上一个同级、或会超过三级时不能缩进
        #expect(try await tree().indent(a.id) == nil)
        #expect(try await tree().indent(a1.id) == nil)
        try await apply(try await tree().indent(b.id), b.id)
        #expect(try await store.card(b.id)?.parentID == a.id)
        // 反缩进成为原上级的下一个同级；顶层不能反缩进
        try await apply(try await tree().outdent(b.id), b.id)
        #expect(try await store.card(b.id)?.parentID == nil)
        #expect(try await tree().outdent(b.id) == nil)

        // 拖到一行中部成为它的子任务；不能拖进自己的子树；灵感拖到任务行上成为提示词、行外不接
        let rows = try await tree().rows(toggled: [])
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let middle = CGPoint(x: 100, y: 66)
        try await apply(try await tree().drop(b.id, rows: rows, frames: frames, at: middle, depthShift: 0)?.move, b.id)
        #expect(try await store.card(b.id)?.parentID == a1.id)
        #expect(try await tree().drop(a.id, rows: rows, frames: frames, at: middle, depthShift: 0) == nil)
        let idea = try await store.createCard(in: nil, body: "日志")
        let onto = try await tree().drop(idea: idea.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 46))
        try await apply(onto?.move, idea.id)
        #expect(try await store.card(idea.id)?.parentID == a1.id)
        #expect(try await tree().drop(idea: idea.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 400)) == nil)
        _ = a2
    }

    /// 层级限制与 Store 同一口径：已完成、不显示的子任务也算层级；拖起来又放回原处什么都不改。
    @Test func 带着已完成第三级子任务的任务不能再缩进_拖起来放回原处不换项目() async throws {
        let top = try await store.createTask("上线", in: nil)
        let first = try await store.createTask("备份", under: top.id)
        let second = try await store.createTask("发布", under: top.id)
        let done = try await store.createTask("写说明", under: second.id)
        try await store.setStatus(done.id, .done)
        let all = try await store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let tree = TaskTree(all.filter { $0.status != .done }, all: all)
        #expect(tree.indent(second.id) == nil)
        let rows = tree.rows(toggled: [])
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let onto = tree.drop(second.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 66), depthShift: 0)
        #expect(onto?.mark != .onto(first.id))
        if let move = onto?.move { try await store.moveCard(second.id, to: move.slot, after: move.after) }

        let site = try await store.createProject(name: "网站", color: "#000000")
        let loose = try await store.createTask("续费域名", in: nil)
        let other = try await store.createTask("换首图", in: site.id)
        let flat = TaskTree(try await store.tasks(.inProgress, .todo).flatMap(\.tasks).filter { [loose.id, other.id].contains($0.id) })
        let flatRows = flat.rows(toggled: [])
        let flatFrames = Dictionary(uniqueKeysWithValues: flatRows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        #expect(flat.drop(loose.id, rows: flatRows, frames: flatFrames, at: CGPoint(x: 100, y: 66), depthShift: 0) == nil)
    }

    // MARK: 共用的小件

    private func tally(_ task: Card) async throws -> PromptTally { PromptTally(try await store.childMarks()[task.id]) }

    private func replied(_ task: Card) async throws -> [Bool] {
        (try await store.childMarks(of: task.id)[task.id] ?? []).filter { !$0.isTask }.map(\.isDone)
    }

    private func primary(_ task: Card) async throws -> UUID? {
        try await TaskDetail.read(task.id, from: store).primaryPrompt(agents: AgentLinks.read(from: store))
    }

    /// 会话 atlas 进入 `state`（时刻晚于刚才的发出：按毫秒比先后）。
    private func enter(_ state: PiWorkState, _ recorder: PiStateRecorder) async throws {
        try await Task.sleep(for: .milliseconds(5))
        _ = try await recorder.update(sessionID: "s1", state: state, title: "atlas", times: PiTimes(stateSince: .now, busySince: nil))
    }

    /// 这一轮做完：对话里多一条回答（已回复靠对话认，会话之后又在忙时也不退回），会话歇下。
    private func answer(_ count: Int, _ recorder: PiStateRecorder) async throws {
        try await Task.sleep(for: .milliseconds(5))
        try await store.writePiTranscript(PiTranscript(
            sessionID: "s1", messages: (1...count).map { PiChatMessage(sessionID: "s1", entryID: "a\($0)", seq: Int64($0), role: .pi, text: "做完 \($0)", at: .now) },
            recap: PiRecap()))
        try await enter(.settled, recorder)
    }

    private func action(of prompt: Card, in task: Card) async throws -> String {
        switch try await TaskDetail.read(task.id, from: store).state(of: prompt, agents: AgentLinks.read(from: store)).action {
        case .handOff: "handOff"
        case .handAgain: "handAgain"
        case .watch(let item): "watch \(item.state.title)"
        case nil: "none"
        }
    }

    private func state(of prompt: Card, in task: Card) async throws -> String {
        switch try await TaskDetail.read(task.id, from: store).state(of: prompt, agents: AgentLinks.read(from: store)) {
        case .unsent: "unsent"
        case .launching: "launching"
        case .working(let item): "working \(item.state.title)"
        case .ended(let item): "ended \(item.state.title)"
        case .replied(let item): "replied \(item?.state.title ?? "")"
        }
    }
}
