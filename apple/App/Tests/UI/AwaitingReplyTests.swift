import CueStore
import Foundation
import Testing
@testable import CuePad

/// 等你分拍板与待回复（WORDS.md）：Cue 留给你回、此刻歇着的会话是待回复——Cue 页不进拍板卡、在上方的待回复提示里，等得最久的在前；
/// 进展页的等你列放在问与待回复的会话（在问的在前），绑着的任务从推进中挪进等你，Cue 的提问只在 Cue 页、不多出卡；"等你 N"两种一起数；名牌的数字账拍板与待回复各数各的（数全部，不只列得下的那几行），
/// "等你 N"与 App 图标角标是两者之和（`CueNow.needsYou`）。
/// 点提示：几个时去进展页的会话段，待回复紧随等你确认、等得最久的在前；对其中一个说了话它就不再待回复，只剩一个时点了直接进那个会话。
@MainActor
struct AwaitingReplyTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func Cue留给你回的歇着会话是待回复_Cue页不进拍板卡_看板等你列排在拍板后_点提示去会话段或那个会话() async throws {
        let workspace = Workspace(services: rig.services)
        _ = try await store.updateCueProfile {
            $0.hostID = "mac-cue"
            $0.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        func settle(_ id: String, _ title: String, minutesAgo: Double) async throws {
            try await recorder.update(
                sessionID: id, state: .settled, title: title, times: PiTimes(stateSince: .now.addingTimeInterval(-minutesAgo * 60), busySince: nil))
            try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [], recap: PiRecap(lastPrompt: title, lastReply: "改好了，你看看？")))
        }
        try await settle("header", "打磨手机 Cue 顶栏", minutesAgo: 5)
        try await settle("glass", "底栏换系统液态玻璃", minutesAgo: 12)
        try await settle("quiet", "清理旧脚本", minutesAgo: 20)
        let dock = try await store.createTask("底栏换玻璃")
        try await store.bindSession("glass", to: dock.id)
        _ = try await store.leaveToYou("header")
        _ = try await store.leaveToYou("glass")
        try await recorder.update(
            sessionID: "deploy", state: .waitingForUser, title: "deploy", question: PiQuestion(promptID: "p", kind: .confirm, text: "部署到生产吗？"))
        _ = try await store.leaveToYou("deploy")  // 留给你的提问照样是拍板

        func thread() async throws -> CueThread { try await CueThread.read(from: store) }
        func now() async throws -> CueNow { CueNow(try await CueDigest.read(from: store), at: .always(), local: CueNow.Local(waiting: nil, here: nil)) }

        var page = try await thread()
        #expect(page.waiting.map(\.id) == ["session/deploy"])
        #expect(page.replies.map(\.sessionID) == ["glass", "header"])  // 等得最久的在前；Cue 没留给你的不算
        let board = try await TaskBoard.read(from: store)
        #expect(board.held.map(\.session.sessionID) == ["deploy", "glass", "header"] && board.held.map(\.deciding) == [true, false, false])
        #expect(board.held[1].item?.task.id == dock.id && !board.advancing.contains { $0.item?.id == dock.id })  // 被待回复占着：只在等你
        #expect(board.held.map(\.title) == ["deploy", "底栏换玻璃", "打磨手机 Cue 顶栏"])  // 写这件事本身的名字
        var cue = try await now()
        #expect(board.count(.waiting) == 3 && cue.needsYou == 3)  // "等你 N"两种一起数，看板等你列同数
        #expect(cue.spoken == "1 件拍板，2 件待回复" && cue.items.prefix(3).map(\.kind) == [.asks, .reply, .reply])

        // Cue 在底栏那件任务上也问一句：只在 Cue 页答，看板不多出卡，那件仍是待回复那一张
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把底栏改动推送到 origin/main"), task: dock.id)
        #expect(try await TaskBoard.read(from: store).held == board.held)
        #expect(try await thread().waiting.map(\.id) == ["session/deploy", "message/\(push.id.uuidString)"])
        try await rig.services.answerCueQuestion(push.id, CueAsk.once)

        // 答了拍板：名牌只剩待回复
        try await recorder.update(sessionID: "deploy", state: .thinking)
        cue = try await now()
        #expect(cue.yours == [CueNow.Entry(kind: .reply, count: 2)])

        // 几个待回复：点提示去进展页的会话段，待回复紧随等你确认（此刻没有在问的，排在最前）
        workspace.projectScope = try await store.createProject(name: "圆桌", color: "#000000").id
        workspace.openReplies(try await thread().replies)
        #expect(workspace.root == .progress && workspace.progressPane == .sessions && workspace.projectScope == nil)
        let list = try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, at: .always(), from: store)
        #expect(list.now.prefix(2).map(\.state.sessionID) == ["glass", "header"])  // 同 Cue 页，等得最久的在前

        // 对其中一个说了话、它动起来：不再待回复；只剩一个，点提示直接进那个会话
        try await recorder.update(sessionID: "header", state: .thinking)
        page = try await thread()
        #expect(page.replies.map(\.sessionID) == ["glass"])
        workspace.openReplies(page.replies)
        #expect(workspace.shownSession?.sessionID == "glass")
        #expect(try await now().yours == [CueNow.Entry(kind: .reply, count: 1)])

        // 多过列得下的行：数字账与角标数的是全部
        for index in 1...8 {
            try await settle("more-\(index)", "会话 \(index)", minutesAgo: Double(index))
            _ = try await store.leaveToYou("more-\(index)")
        }
        cue = try await now()
        #expect(cue.items.count == CueNow.itemLimit && cue.yours == [CueNow.Entry(kind: .reply, count: 9)] && cue.needsYou == 9)
    }

    /// 出错的会话留给你回后，对它再说一句：话一发出它就不再待回复——看板上它绑着的任务当场从等你回到推进中、写话到哪了（在跑），
    /// 不等 Mac 送到；会话动起来后写它自己的状态。点卡进卡上写的那个会话，有子任务的任务也一样（此刻干活那一步的会话）；没有会话的打开任务。
    @Test func 出错留给你回后再说一句_看板当场回到推进中_点卡进卡上的会话() async throws {
        let workspace = Workspace(services: rig.services)
        _ = try await store.updateCueProfile {
            $0.hostID = "mac-cue"
            $0.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
        let recorder = PiStateRecorder(store: store, hostID: "mac-a")
        try await recorder.update(
            sessionID: "billing", state: .error, detail: "connection refused", title: "billing",
            times: PiTimes(stateSince: .now.addingTimeInterval(-600), busySince: nil))
        let parent = try await store.createTask("导入旧数据")
        let first = try await store.createTask("先读一遍", under: parent.id)
        let second = try await store.createTask("再导进去", under: parent.id)
        try await store.bindSession("billing", to: second.id)
        _ = try await store.leaveToYou("billing")
        let idle = try await store.createTask("还没开始的")

        var board = try await TaskBoard.read(from: store)
        #expect(board.held.map(\.session.sessionID) == ["billing"] && board.held.first?.item?.id == parent.id)
        // 卡写的是此刻有会话的那一步（第二步），不是第一个没做完的
        #expect(board.held.first?.item?.agent?.state.sessionID == "billing")
        #expect(board.held.first?.item?.agent?.state.sessionID != first.piSessionID)

        let session = try #require(board.held.first?.item?.agent?.state)
        let box = rig.services.settings.replyDraftBinding(for: session.id)
        box.wrappedValue = ComposerDraft(text: "网络好了，接着做")
        await workspace.speak(to: .session(session, mode: .send), from: box) { $0.text }.value

        board = try await TaskBoard.read(from: store)
        #expect(board.held.isEmpty && board.count(.waiting) == 0)
        let work = try #require(board.advancing.first { $0.item?.id == parent.id })
        var pulse = workspace.pulse(of: work.agent)
        #expect(pulse.tier == .running && pulse.word == nil && workspace.shownInHeader(session, delivery: work.agent?.delivery).label == "发送中")

        try await recorder.update(sessionID: "billing", state: .thinking, times: PiTimes(stateSince: .now, busySince: .now))
        board = try await TaskBoard.read(from: store)
        pulse = workspace.pulse(of: try #require(board.advancing.first { $0.item?.id == parent.id }).agent)
        #expect(pulse.shown?.status == .working(.thinking))

        // 点卡：有会话的进那个会话（有子任务也是），没有会话的打开任务
        let item = try #require(board.advancing.first { $0.item?.id == parent.id }?.item)
        workspace.enter(item.task, session: item.agent?.state)
        #expect(workspace.shownSession?.sessionID == "billing" && workspace.openTask == nil)
        let todo = try #require(board.todo.first { $0.id == idle.id })
        workspace.enter(todo.task, session: todo.agent?.state)
        #expect(workspace.openTask?.task == idle.id)
    }
}
