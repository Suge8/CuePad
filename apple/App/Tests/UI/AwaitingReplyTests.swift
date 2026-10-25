import CueStore
import Foundation
import Testing
@testable import CuePad

/// 等你只放拍板，待回复另算（WORDS.md）：Cue 留给你回、此刻歇着的会话不进等你（Cue 页等你卡、看板等你列、"等你 N"、名牌），
/// 在 Cue 页的待回复提示里，等得最久的在前；名牌有拍板只说拍板，没有了才说几个会话待回复（数全部，不只排得下的珠子）。
/// 点提示：几个时去进展页的会话段，待回复排最前、等得最久的在前；对其中一个说了话它就不再待回复，只剩一个时点了直接进那个会话。
@MainActor
struct AwaitingReplyTests {
    let rig = TestApp()
    var store: CueStore { rig.services.store }

    @Test func Cue留给你回的歇着会话不在等你里_在待回复里_点提示去会话段或那个会话() async throws {
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
        #expect(try await TaskBoard.read(from: store).waiting.map(\.id) == ["session/deploy"])
        var cue = try await now()
        #expect(try await CueDigest.read(from: store).waiting == 1)
        #expect(cue.headline == "1 件等你拍板" && cue.beads.prefix(3).map(\.kind) == [.asks, .reply, .reply])

        // 答了拍板：名牌改说待回复
        try await recorder.update(sessionID: "deploy", state: .thinking)
        cue = try await now()
        #expect(cue.headline == "2 个会话待回复")

        // 几个待回复：点提示去进展页的会话段，待回复排在最前
        workspace.projectScope = try await store.createProject(name: "圆桌", color: "#000000").id
        workspace.showReplies()
        #expect(workspace.root == .progress && workspace.progressPane == .sessions && workspace.projectScope == nil)
        let list = try await PiSessionList.read(text: "", historyLimit: PiSessionList.pageSize, at: .always(), from: store)
        #expect(list.now.prefix(2).map(\.state.sessionID) == ["glass", "header"])  // 同 Cue 页，等得最久的在前

        // 对其中一个说了话、它动起来：不再待回复；只剩一个，点提示直接进那个会话
        try await recorder.update(sessionID: "header", state: .thinking)
        page = try await thread()
        let only = try #require(page.replies.first)
        #expect(page.replies.count == 1 && only.sessionID == "glass")
        workspace.openSession(only.id, sessionID: only.sessionID)
        #expect(workspace.shownSession?.sessionID == "glass")
        #expect(try await now().headline == "1 个会话待回复")

        // 多过排得下的珠子：名牌数的是全部
        for index in 1...8 {
            try await settle("more-\(index)", "会话 \(index)", minutesAgo: Double(index))
            _ = try await store.leaveToYou("more-\(index)")
        }
        cue = try await now()
        #expect(cue.beads.count == CueNow.beadLimit && cue.headline == "9 个会话待回复")
    }
}
