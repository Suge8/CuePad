import CueStore
import Foundation
import Testing
@testable import CuePad

/// 进展页只看不答：等你列的拍板卡写短事由，点了去 Cue 页答，点的那一问排到拍板卡最前（不是原本最前的那件也一样）。
@MainActor
struct BoardAskTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    @Test func 看板点后来的那一问_去Cue页且它排到拍板卡最前() async throws {
        let workspace = Workspace(services: app.services)
        let first = try await store.addCueMessage(.cue, text: "要推送吗？", ask: try CueAsking(.push, action: "把发言顺序的修复推送到 origin/main"))
        let later = try await store.addCueMessage(.cue, text: "要删掉旧脚本吗？", ask: try CueAsking(.delete, action: "删掉 scripts/billing-legacy 目录"))

        let board = try await TaskBoard.read(from: store)
        #expect(board.waiting.map(\.brief) == ["把发言顺序的修复推送到 origin/main", "删掉 scripts/billing-legacy 目录"])
        #expect(try await CueThread.read(from: store, showsSteps: false, asking: workspace.cueAsking).waiting.first?.message?.id == first.id)

        workspace.askOnCuePage(later.id)
        #expect(workspace.top == .cue)
        let thread = try await CueThread.read(from: store, showsSteps: false, asking: workspace.cueAsking)
        #expect(thread.waiting.map(\.message?.id) == [later.id, first.id])
    }
}
