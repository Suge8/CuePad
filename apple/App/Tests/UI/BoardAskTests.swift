import CueStore
import Foundation
import Testing
@testable import CuePad

/// 进展页只看不答：等你列一件一张卡，写这件事本身的名字（任务名；不落在任务上的 Cue 提问写它要做的事），同一件任务上的几件收成一张、写件数，
/// 列头仍数条；点了去 Cue 页答，拍板卡露的就是点的那一问（不是最早的那件也一样，在拍板卡上换过一件再点回来也一样）。拍板与待回复落在同一件任务上也是一张：
/// 有拍板时是拍板（赭黄问号）、点了先去答它，答完只剩待回复（墨点）、点了进那个会话。
@MainActor
struct BoardAskTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 看板等你列一件一张卡_写任务名_点哪一问拍板卡就露哪一问() async throws {
        let workspace = Workspace(services: app.services)
        let task = try await store.createTask("发言轮次乱序")
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把发言顺序的修复推送到 origin/main"), task: task.id)
        let loose = try await store.addCueMessage(.cue, text: "要删掉旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/billing-legacy 目录"))
        _ = try await store.addCueMessage(.cue, text: "要发布吗？", ask: try CueAsking(.release, action: "发布 1.4.3"), task: task.id)

        let board = try await TaskBoard.read(from: store)
        #expect(board.held.map(\.title) == ["发言轮次乱序", "删掉 scripts/billing-legacy 目录"])
        #expect(board.held.map(\.count) == [2, 1] && board.count(.waiting) == 3)
        let thread = try await CueThread.read(from: store)
        func shown() -> UUID? { CueWaitDock.current(in: thread.waiting, asking: workspace.cueAsking)?.message?.id }
        #expect(thread.waiting.count == 3 && shown() == push.id)  // 没点过：露最早的

        workspace.open(board.held[1].destination)
        #expect(workspace.top == .cue && shown() == loose.id)

        // 在拍板卡上换到另一件（滑卡、小箭头写的同一处），再从看板点回来：还是点的那一问
        workspace.cueAsking = thread.waiting[0].id
        workspace.open(board.held[1].destination)
        #expect(shown() == loose.id)
    }

    @Test func 同一任务上有拍板也有待回复_合成一张_先去拍板_答完变待回复进会话() async throws {
        let workspace = Workspace(services: app.services)
        _ = try await store.updateCueProfile {
            $0.hostID = "mac-cue"
            $0.enabledAt = .now
        }
        try await store.recordMacPresence(host: "mac-cue") { true }
        let task = try await store.createTask("底栏换玻璃")
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "glass", state: .settled, title: "底栏换系统液态玻璃")
        try await store.bindSession("glass", to: task.id)
        _ = try await store.leaveToYou("glass")
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把底栏改动推送到 origin/main"), task: task.id)

        func onlyCard() async throws -> TaskBoard.Held {
            let held = try await TaskBoard.read(from: store).held
            #expect(held.count == 1)  // 同一件任务只有一张
            return try #require(held.first)
        }

        var card = try await onlyCard()
        #expect(card.title == "底栏换玻璃" && card.deciding && card.count == 2)
        workspace.open(card.destination)
        #expect(workspace.top == .cue)
        let thread = try await CueThread.read(from: store)
        #expect(CueWaitDock.current(in: thread.waiting, asking: workspace.cueAsking)?.message?.id == push.id)

        try await app.services.answerCueQuestion(push.id, CueAsk.once)
        card = try await onlyCard()
        #expect(card.title == "底栏换玻璃" && !card.deciding && card.count == 1)
        workspace.open(card.destination)
        #expect(workspace.shownSession?.sessionID == "glass")
    }
}
