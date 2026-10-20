import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 任务优先的主动线，按用户走的路写：灵感设为任务 → 开始把正文交给 Agent（话在路上、没送到可重发、送达后正文留着）→ 完成并归档；中途撤销；整理任务的层级；
/// 各处写的任务数是同一批。规则单测（行的状态怎么推、任务树怎么算）都从这些动作里走一遍，不单独测。
struct TaskFlowTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }
    private let atlas = SendTarget(kind: .piSession, name: "atlas", ref: "s1")

    // MARK: 灵感走完全程

    @Test func 设为任务_开始把正文交给Agent_没送到在会话里看_送达后正文留着_完成并归档() async throws {
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let idea = try await store.createCard(in: project.id, body: "修乱序\n日志在 logs/0918.txt")
        let workspace = Workspace(services: rig.services)

        // 设为任务：第一行是标题，其余是它的正文，不拆出别的卡
        try await workspace.setTodo(idea.id, true)
        let task = try #require(try await store.card(idea.id))
        #expect(task.title == "修乱序" && task.rest == "日志在 logs/0918.txt")
        #expect(try await store.children(of: task.id).isEmpty)
        #expect(try await next(task) == .start(leaf: task))

        // 开始：正文连同标题交出去；话在路上、没送到都看会话那一格，不再给"开始"
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "s1", state: .settled, title: "atlas")
        let delivers = Mutex(false)
        let executor = DeliveryExecutor(store: store, hostID: "mac-a", onIssue: { Issue.record("\($0)") }) { [store, atlas] request in
            guard delivers.withLock({ $0 }) else { return .failed("会话在送达前关掉了") }
            _ = try? await store.recordSend(request.content, to: atlas, card: request.cardID)
            return .succeeded
        }
        let request = try await store.requestDelivery(Outgoing.text(of: task), to: atlas, on: "mac-a", card: task.id)
        guard case .agent(let sending, _) = try await next(task) else { throw Unexpected.next }
        #expect(sending.isRunning && sending.undelivered == nil)
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequest(request.id)?.status }) { $0 == .known(.failed) }
        guard case .agent(let failed, _) = try await next(task) else { throw Unexpected.next }
        #expect(failed.undelivered != nil)

        // 重发送达：任务进行中并记着会话，正文留在任务上，发送记录留着话
        delivers.withLock { $0 = true }
        try await store.requestDelivery(Outgoing.text(of: task), to: atlas, on: "mac-a", card: task.id)
        _ = try await eventually(store, { try $0.card(task.id)?.piSessionID }) { $0 == "s1" }
        await executor.stop()
        let started = try #require(try await store.card(task.id))
        #expect(started.status == .inProgress && started.body == "修乱序\n日志在 logs/0918.txt")
        #expect(try RawDB(rig.services.location.databaseURL).rows("SELECT content FROM sendRecords") == [["修乱序\n日志在 logs/0918.txt"]])

        // 任务不自动完成；用户勾选，提示里给归档
        try await workspace.toggle(task.id)
        #expect(workspace.notice?.text == "已完成")
        let archive = try #require(workspace.notice?.action)
        #expect(archive.title == "归档")
        try await archive.run()
        #expect(try await store.card(task.id)?.archivedAt != nil)
    }

    // MARK: 会话与任务

    #if os(macOS)
    /// 一个会话绑两件事：绑定不发正文（话在会话里说）；做完一件会话照常，都做完才请它所在的 Mac 结束。
    @Test func 一个会话绑两件事_绑定不发正文_都做完才结束会话() async throws {
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let first = try await store.createTask("复现乱序\n先复现，别改代码", in: project.id)
        let second = try await store.createTask("补重连用例", in: project.id)
        try await PiStateRecorder(store: store, hostID: "mac-other").update(sessionID: "s1", state: .thinking, title: "atlas")
        rig.services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())

        try await store.bindSession("s1", to: first.id)
        try await store.bindSession("s1", to: second.id)
        #expect(rig.services.settings.replyDraft(for: PiSessionState.recordID(sessionID: "s1")).isEmpty(accepting: .images))
        #expect(try await store.deliveryRequests().isEmpty)
        #expect(try await store.card(first.id)?.rest == "先复现，别改代码")
        #expect(try await Set(store.tasks(boundTo: "s1").map(\.task.id)) == [first.id, second.id])

        let ends = { [store] in try await store.deliveryRequests().filter { $0.mode == .known(.end) }.map(\.target.ref) }
        try await workspace.toggle(first.id)
        #expect(try await ends().isEmpty)
        try await workspace.toggle(second.id)
        #expect(try await ends() == ["s1"])
    }

    /// 分步做一件事（与 Cue 同一条规则）：上一步做完、下一步还没开工时会话留着；下一步"开始"接着用它——只发这一步的标题与正文，不开新会话；
    /// 要新会话就在"绑定会话"里选"开新会话"：第一句先带顶层任务的标题与正文作背景，再接这一步的；最后一步做完，会话才结束。
    @Test func 分步做_下一步接着用上一步的会话_最后一步做完才结束() async throws {
        try await rig.offersPi()
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/tmp/roundtable", for: project.id)
        let task = try await store.createTask("加语言参数\n命令行要能切中英文", in: project.id)
        let first = try await store.createTask("加 --lang", under: task.id)
        let second = try await store.createTask("写 README", under: task.id)
        let third = try await store.createTask("发版\n打 tag 再发", under: task.id)
        try await PiStateRecorder(store: store, hostID: "mac-other").update(sessionID: "s1", state: .settled, title: "atlas")
        rig.services.liveSessions.apply(try await LiveSessions.Page.read(from: store), at: .always())
        try await store.bindSession("s1", to: first.id)
        let requests = { [store] (mode: DeliveryMode) in try await store.deliveryRequests().filter { $0.mode == .known(mode) } }

        try await workspace.toggle(first.id)
        #expect(try await requests(.end).isEmpty)

        try await store.updateCard(second.id) { $0.rest = "照 --lang 的用法写 README" }
        workspace.handOff(try #require(try await store.card(second.id)))
        let sent = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.send) } }) { $0 != nil }
        #expect(sent?.target.ref == "s1" && sent?.content == "写 README\n照 --lang 的用法写 README")
        #expect(try await requests(.start).isEmpty)

        workspace.startFresh(third)
        let launch = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil }
        #expect(launch?.cardID == third.id && launch?.launch?.project == project.id)
        #expect(launch?.launch?.prompt == "加语言参数\n命令行要能切中英文\n\n发版\n打 tag 再发")
        _ = try await store.withdrawDelivery(try #require(launch).id)  // 本机不执行：开新会话的去向核对完即可

        // 会话所在的 Mac 送到：记下这次发送，这一步绑上会话
        let executor = DeliveryExecutor(store: store, hostID: "mac-other", onIssue: { Issue.record("\($0)") }) { [store] request in
            _ = try? await store.recordSend(request.content, to: request.target, card: request.cardID)
            return .succeeded
        }
        try await executor.start()
        _ = try await eventually(store, { try $0.card(second.id)?.piSessionID }) { $0 == "s1" }
        await executor.stop()
        try await workspace.toggle(second.id)
        #expect(try await requests(.end).isEmpty)  // "发版"还没开工，默认接着用它
        try await workspace.toggle(third.id)
        #expect(try await requests(.end).map(\.target.ref) == ["s1"])
    }

    /// 行尾那一格是"开始"；点它开一个会话，正在开时不再给"开始"，没开成不算交给过，重新给"开始"。
    @Test func 点开始交给Agent_正在开时不再给开始_没开成重新给() async throws {
        try await rig.offersPi()
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/tmp/roundtable", for: project.id)
        let task = try await store.createTask("修发言乱序", in: project.id)
        #expect(try await next(task) == .start(leaf: task))

        workspace.handOff(task)
        let launch = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil }
        let request = try #require(launch)
        #expect(request.launch?.project == project.id)
        #expect(try await next(task) == nil)

        let executor = DeliveryExecutor(store: store, hostID: request.hostID, onIssue: { Issue.record("\($0)") }) { _ in .failed("这台 Mac 上开不了会话") }
        try await executor.start()
        _ = try await eventually(store, { try $0.deliveryRequest(request.id)?.status }) { $0 == .known(.failed) }
        await executor.stop()
        #expect(try await next(task) == .start(leaf: task))
    }
    #endif

    // MARK: 撤销与批量

    @Test func 设为任务_删除_都能撤销_勾选以最新状态为准() async throws {
        let workspace = Workspace(services: rig.services)
        let body = "上线前检查\n把 changelog 过一遍\n看下崩溃率"
        let multi = try await store.createCard(body: body)
        try await workspace.setTodo(multi.id, true)
        #expect(workspace.notice?.text == "已设为任务")
        try await #require(workspace.notice?.action).run()
        #expect(try await store.cards(in: Project.defaultID).map(\.body) == [body])
        #expect(try await store.card(multi.id)?.isTask == false)

        let idea = try await store.createCard(body: "续费域名")
        try await workspace.trash(idea.id)
        #expect(workspace.notice?.text == "已删除")
        #expect(try await store.trashedCards().map(\.id) == [idea.id])
        try await #require(workspace.notice?.action).run()
        #expect(try await store.trashedCards().isEmpty)

        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let stale = try await store.createTask("续费域名")
        try await workspace.toggle(stale.id)
        try await workspace.toggle(stale.id)  // 手里的副本已过时：切换以 Store 当前状态为准
        #expect(try await store.card(stale.id)?.status == .todo)

        workspace.convertToTasks("- 写发布说明\n\n- 更新截图", in: project.id)
        try await eventually("转好任务") { workspace.notice?.text == "已转为 2 个任务" }
        #expect(try await store.tasks(.todo).flatMap(\.tasks).filter { $0.projectID == project.id }.map(\.body) == ["写发布说明", "更新截图"])
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
        try await Task.sleep(for: .milliseconds(2))  // 完成时间存到毫秒：同一毫秒里做完的两件分不出先后
        let shipped = try await store.createTask("发版", in: project)
        try await store.setStatus(shipped.id, .done)
        let closed = try await store.createTask("收尾", in: project)
        let reopened = try await store.createTask("补文档", under: closed.id)
        try await store.setStatus(closed.id, .done)
        try await store.setStatus(reopened.id, .todo)  // 上级跟着不再算做完
        let archived = try await store.createTask("旧的", in: project)
        _ = try await store.createTask("旧的步骤", under: archived.id)
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
        #expect(Set(board.todo.map(\.id)) == Set(open))  // 没有会话在做：开始过的也在待办
        let done = [fix.id, shipped.id]
        #expect(board.done.map(\.id) == [shipped.id, fix.id] && page.taskCounts.done == done.count)  // 做完按完成时间排，最近的在前
    }

    #if os(macOS)
    /// 任务页的流水看板（Mac 侧栏"任务"与手机任务页同一份）：拖到在管就是开始（同"开始"，`Workspace.handOff`），会话开好它就在管；
    /// Cue 问到它，它挪到等你，没绑任务的会话在问也在这一列；在管、等你两列的数就是 Cue 摘要里的数；答完回到在管；
    /// 拖到做完就是做完（同点完成圈，`Workspace.toggle`），落在今天做完的那一列，它还活着的会话留在在管；做完了 Cue 还在问它，它只在等你。
    @Test func 看板_拖到在管就是开始_Cue问到它挪到等你_两列的数同Cue摘要_拖到做完就是做完_做完了还在问只在等你() async throws {
        try await rig.offersPi()
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        try await store.setDirectory("/tmp/roundtable", for: project.id)
        let task = try await store.createTask("修发言乱序", in: project.id)
        let other = try await store.createTask("补重连用例", in: project.id)
        func board() async throws -> TaskBoard { try await TaskBoard.read(from: store) }
        func expectCountsMatchCue(_ board: TaskBoard) async throws {
            let digest = try await CueDigest.read(from: store)
            #expect(board.count(.managing) == digest.managing && board.count(.waiting) == digest.waiting)
        }
        #expect(try await Set(board().todo.map(\.id)) == [task.id, other.id])

        workspace.handOff(task)
        let launch = try await eventually(store, { try $0.deliveryRequests().first { $0.mode == .known(.start) } }) { $0 != nil }
        let token = try #require(launch?.launch?.token)
        try await PiStateRecorder(store: store, hostID: TestApp.hostID).update(sessionID: "s1", state: .thinking, title: "修发言乱序", launchToken: token)
        var columns = try await board()
        #expect(columns.managing.map(\.item?.id) == [task.id] && columns.todo.map(\.id) == [other.id])
        try await expectCountsMatchCue(columns)

        let ask = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送发言顺序的修复"), task: task.id)
        try await PiStateRecorder(store: store, hostID: "mac-a")
            .update(sessionID: "rename", state: .waitingForUser, title: "rename", question: PiQuestion(promptID: "p", kind: .text, text: "新分支叫什么？"))
        columns = try await board()
        #expect(columns.managing.isEmpty)
        #expect(columns.waiting.map(\.item?.id) == [task.id, nil])
        try await expectCountsMatchCue(columns)

        try await workspace.services.answerCueQuestion(ask.id, CueAsk.once)
        #expect(try await board().managing.map(\.item?.id) == [task.id])
        try await workspace.toggle(task.id)
        columns = try await board()
        #expect(columns.done.map(\.id) == [task.id] && columns.managing.map(\.id) == ["session/s1"] && columns.waiting.count == 1)
        try await expectCountsMatchCue(columns)

        // 做完了 Cue 还在问它：它只在等你，做完列与实时活动的"今天做完"都不再算它
        _ = try await store.addCueMessage(.cue, text: "要删分支吗？", ask: try CueAsking(.delete, action: "删掉修发言乱序的分支"), task: task.id)
        columns = try await board()
        #expect(columns.done.isEmpty && columns.waiting.compactMap(\.item?.id) == [task.id])
        #expect(try await CueActivityState.Reading.read(from: store).done.isEmpty)
        try await expectCountsMatchCue(columns)
    }
    #endif

    /// 在管与等你（Cue 那一行、看板中间两列同一份）：会话在做的顶层任务在管；Cue 问到它的步骤、它的会话在问你，它就从在管挪到等你，一处在等算一件；
    /// 没落在任务上的提问也算等你；答完回到在管。
    @Test func 在管与等你_问到哪件哪件挪到等你_答完回到在管() async throws {
        let workspace = Workspace(services: rig.services)
        let project = try await store.createProject(name: "圆桌", color: "#000000")
        let release = try await store.createTask("发布 v1.4", in: project.id)
        let step = try await store.createTask("推送到 TestFlight", under: release.id)
        let canvas = try await store.createTask("画布缩放", in: project.id)
        _ = try await store.createTask("登录回调", in: project.id)
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "push", state: .thinking, title: "push-testflight")
        try await store.bindSession("push", to: step.id)
        try await recorder.update(sessionID: "zoom", state: .thinking, title: "canvas-zoom")
        try await store.bindSession("zoom", to: canvas.id)
        func digest() async throws -> CueDigest { try await CueDigest.read(from: store) }
        #expect(try await Set(digest().tally.managing.map(\.id)) == ["task/\(release.id.uuidString)", "task/\(canvas.id.uuidString)"])

        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "推送 v1.4"), task: step.id)
        _ = try await store.addCueMessage(.cue, text: "要删旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/legacy"))
        try await recorder.update(sessionID: "zoom", state: .waitingForUser, question: PiQuestion(promptID: "p", kind: .confirm, text: "改锚点？"))
        var tally = try await digest().tally
        #expect(tally.managing.isEmpty)
        #expect(tally.waiting.map(\.task) == [release.id, nil, canvas.id])

        try await workspace.services.answerCueQuestion(push.id, CueAsk.once)
        tally = try await digest().tally
        #expect(tally.managing.map(\.id) == ["task/\(release.id.uuidString)"] && tally.waiting.count == 2)
    }

    /// 在管只算 Cue 此刻在做的，与它信封里的"在做"同一份：开过工、会话都结束了的任务（在等你自己去办的事）不算，
    /// 它没丢也没做完，回到待办；会话恢复了又回到在管。没绑没做完的任务的活会话也在在管。
    @Test func 会话都结束了的任务不算在管_回到待办_数同信封() async throws {
        let card = try await store.createTask("开 U 卡")
        let bitget = try await store.createTask("bitget", under: card.id)
        _ = try await store.createTask("KYC", under: card.id)
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(sessionID: "kyc", state: .settled, title: "bitget")
        try await store.bindSession("kyc", to: bitget.id)
        try await recorder.update(sessionID: "kyc", state: .ended)
        let live = try await store.createTask("修登录")
        try await recorder.update(sessionID: "login", state: .thinking, title: "修登录")
        try await store.bindSession("login", to: live.id)
        try await recorder.update(sessionID: "term", state: .settled, title: "终端里的")
        func inEnvelope() async throws -> Int { try await store.cueBoard().active.count }  // 信封的"在做 N 件"数的就是它

        var board = try await TaskBoard.read(from: store)
        #expect(board.managing.map(\.id) == ["task/\(live.id.uuidString)", "session/term"])  // 任务在前，没绑任务的会话在后
        #expect(board.todo.map(\.id) == [card.id] && board.todo.first?.task.status == .inProgress)
        #expect(try await CueDigest.read(from: store).managing == 2)
        #expect(try await inEnvelope() == 2)

        try await recorder.update(sessionID: "kyc", state: .thinking)
        board = try await TaskBoard.read(from: store)
        #expect(Set(board.managing.map(\.id)) == ["task/\(card.id.uuidString)", "task/\(live.id.uuidString)", "session/term"] && board.todo.isEmpty)
        #expect(try await inEnvelope() == 3)
    }

    // MARK: 整理任务的层级

    /// a（a1、a2）、b。界面给出的每一次移动，Store 都接受。
    @Test func 整理任务_缩进_反缩进_拖放_界面给出的移动Store都接受() async throws {
        let a = try await store.createTask("a")
        let b = try await store.createTask("b")
        try await store.moveCard(a.id, to: .top(project: Project.defaultID), after: nil)
        let a1 = try await store.createTask("a1", under: a.id)
        let a2 = try await store.createTask("a2", under: a.id)
        func tree() async throws -> TaskTree { TaskTree(try await store.tasks(.todo).flatMap(\.tasks)) }
        func apply(_ move: TaskMove?, _ id: UUID) async throws {
            let move = try #require(move)
            try await store.moveCard(id, to: move.slot, after: move.after)
        }

        let listed = try await tree().rows()
        #expect(listed.map(\.id) == [a.id, a1.id, a2.id, b.id] && listed.map(\.depth) == [0, 1, 1, 0])

        // 缩进成为上一个同级的最后一个步骤；没有上一个同级、或任务会超过两级时不能缩进
        #expect(try await tree().indent(a.id) == nil)
        #expect(try await tree().indent(a1.id) == nil)
        #expect(try await tree().indent(a2.id) == nil)
        try await apply(try await tree().indent(b.id), b.id)
        #expect(try await store.card(b.id)?.parentID == a.id)
        // 反缩进成为原上级的下一个同级；顶层不能反缩进
        try await apply(try await tree().outdent(b.id), b.id)
        #expect(try await store.card(b.id)?.parentID == nil)
        #expect(try await tree().outdent(b.id) == nil)

        // 拖到一行中部成为它的步骤；不能拖进自己的子树
        let rows = try await tree().rows()
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let middle = CGPoint(x: 100, y: 66)
        try await apply(try await tree().drop(b.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 22), depthShift: 0)?.move, b.id)
        #expect(try await store.card(b.id)?.parentID == a.id)
        #expect(try await tree().drop(a.id, rows: rows, frames: frames, at: middle, depthShift: 0) == nil)
    }

    /// 层级限制与 Store 同一口径：已完成、不显示的步骤也算层级；拖起来又放回原处什么都不改。
    /// 点掉已完成步骤的圆圈：不再算做完只有一种——它与已完成的上级清掉完成，开始过的回进行中、没开始过的回待办，在归档里的整件取回；
    /// 上级从步骤推出开始，步骤开始过它就跟着进行中。
    @Test func 点掉已完成步骤的圆圈_上级跟着不再算做完_整件取回归档() async throws {
        let task = try await store.createTask("发布")
        let step = try await store.createTask("跑检查", under: task.id)
        try await store.setStatus(step.id, .inProgress)
        let workspace = Workspace(services: rig.services)
        try await workspace.toggle(task.id)
        try await workspace.archive(task.id)
        #expect(try await store.card(step.id)?.status == .done)
        #expect(try await store.archived().count == 1)

        try await workspace.toggle(step.id)
        #expect(try await store.card(step.id)?.status == .inProgress)
        #expect(try await store.card(task.id)?.status == .inProgress)
        #expect(try await store.archived().isEmpty)
    }

    @Test func 带着已完成步骤的任务不能再缩进_拖起来放回原处不换项目() async throws {
        let second = try await store.createTask("发布")
        let first = try await store.createTask("备份")
        let done = try await store.createTask("写说明", under: second.id)
        try await store.setStatus(done.id, .done)
        let all = try await store.tasks(.inProgress, .todo, .done).flatMap(\.tasks)
        let tree = TaskTree(all.filter { $0.status != .done }, all: all)
        #expect(tree.indent(second.id) == nil)
        let rows = tree.rows()
        let frames = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let onto = tree.drop(second.id, rows: rows, frames: frames, at: CGPoint(x: 100, y: 22), depthShift: 0)
        #expect(onto?.mark != .onto(first.id))
        if let move = onto?.move { try await store.moveCard(second.id, to: move.slot, after: move.after) }

        let site = try await store.createProject(name: "网站", color: "#000000")
        let loose = try await store.createTask("续费域名")
        let other = try await store.createTask("换首图", in: site.id)
        let flat = TaskTree(try await store.tasks(.inProgress, .todo).flatMap(\.tasks).filter { [loose.id, other.id].contains($0.id) })
        let flatRows = flat.rows()
        let flatFrames = Dictionary(uniqueKeysWithValues: flatRows.enumerated().map { ($1.id, CGRect(x: 0, y: CGFloat($0) * 44, width: 300, height: 44)) })
        let home = try #require(flatFrames[loose.id])
        #expect(flat.drop(loose.id, rows: flatRows, frames: flatFrames, at: CGPoint(x: 100, y: home.midY), depthShift: 0) == nil)
    }

    // MARK: 共用的小件

    private enum Unexpected: Error { case next }

    /// 任务行"下一步"那一格（叶子，与行上读的同一份交给的会话）。
    private func next(_ task: Card) async throws -> TaskNext? {
        let agents = try await AgentLinks.read(from: store)
        return Workspace(services: rig.services).next(for: task, in: agents, steps: nil)
    }
}
