import CueStore
import Foundation
import Testing
@testable import CuePad

/// 看板的等你列只放在等你的会话，点了进会话；Cue 的提问不上看板，只在 Cue 页答。落在任务上的 Cue 提问不把任务挪进等你：
/// 同一件任务上 Cue 在问、它的会话也待回复时，等你列只有会话那一张（写任务名），列头只数它。
@MainActor
struct BoardAskTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func Cue的提问不上看板_会话待回复一张_点了进会话() async throws {
        let workspace = Workspace(services: app.services)
        _ = try await store.updateCueProfile {
            $0.hostID = "mac-cue"
            $0.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
        let task = try await store.createTask("底栏换玻璃")
        let other = try await store.createTask("发言轮次乱序")
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "glass", state: .settled, title: "底栏换系统液态玻璃")
        try await store.bindSession("glass", to: task.id)
        _ = try await store.leaveToYou("glass")
        _ = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把底栏改动推送到 origin/main"), task: task.id)
        _ = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把发言顺序的修复推送到 origin/main"), task: other.id)
        _ = try await store.addCueMessage(.cue, text: "要删掉旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/billing-legacy 目录"))

        let board = try await TaskBoard.read(from: store)
        #expect(board.held.map(\.title) == ["底栏换玻璃"] && board.held.map { $0.asks == nil } == [true] && board.count(.waiting) == 1)
        #expect(board.todo.contains { $0.id == other.id })  // 只有 Cue 在问的任务留在原处
        #expect(try await CueThread.read(from: store).waiting.count == 3)  // 三问都在 Cue 页

        try await app.services.answerCueQuestion(try #require(try await store.cueMessagesWaitingForYou().first).id, CueAsk.once)
        #expect(try await TaskBoard.read(from: store).held.map(\.title) == ["底栏换玻璃"])  // 答了提问，会话那张不动
        workspace.openSession(board.held[0].session.id, sessionID: board.held[0].session.sessionID)
        #expect(workspace.shownSession?.sessionID == "glass")
    }
}
