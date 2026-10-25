import CueStore
import Foundation
import Testing
@testable import CuePad

/// 进展页只看不答：等你列一件一张卡，写这件事本身的名字（任务名；不落在任务上的 Cue 提问写它要做的事），同一件任务上的几件收成一张、写件数，
/// 列头仍数条；点了去 Cue 页答，点的那一问排到拍板卡最前（不是原本最前的那件也一样）。
@MainActor
struct BoardAskTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 看板等你列一件一张卡_写任务名_点后来的那一问去Cue页且它排到最前() async throws {
        let workspace = Workspace(services: app.services)
        let task = try await store.createTask("发言轮次乱序")
        let push = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把发言顺序的修复推送到 origin/main"), task: task.id)
        let loose = try await store.addCueMessage(.cue, text: "要删掉旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/billing-legacy 目录"))
        _ = try await store.addCueMessage(.cue, text: "要发布吗？", ask: try CueAsking(.release, action: "发布 1.4.3"), task: task.id)

        let board = try await TaskBoard.read(from: store)
        #expect(board.held.map(\.title) == ["发言轮次乱序", "删掉 scripts/billing-legacy 目录"])
        #expect(board.held.map(\.count) == [2, 1] && board.count(.waiting) == 3)
        #expect(try await CueThread.read(from: store, showsSteps: false, asking: workspace.cueAsking).waiting.first?.message?.id == push.id)

        workspace.askOnCuePage(loose.id)
        #expect(workspace.top == .cue)
        let thread = try await CueThread.read(from: store, showsSteps: false, asking: workspace.cueAsking)
        #expect(thread.waiting.first?.message?.id == loose.id && thread.waiting.count == 3)
    }
}
