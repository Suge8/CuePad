#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// Cue 的开关（设置里那一行、Cue 页"⋯"，都经 `AppServices.turnCue`）：关了是停用，各处写"已停用"；
/// 再打开回到停用前那台 Mac 接着干活，不因为是在这台上按的就抢到这台。
@MainActor
struct CueSwitchTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var store: CueStore { app.services.store }

    @Test func 关了是已停用_再开回到停用前那台() async throws {
        try await app.connect(.pi)
        services.startSync()
        try await app.syncs()
        try await store.recordMacAgents(host: "mac-old", name: "Mac Studio", [MacAgent(kind: .pi, model: nil, models: [])])
        try await store.recordMacPresence(host: "mac-old") { true }
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-old"
            profile.enabledAt = .now
        }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.followCue() }
        defer { following.cancel() }
        try await eventually("在 Mac Studio 上运行") { workspace.cue.now.quietLine == "在「Mac Studio」上运行" }

        workspace.turnCue(false)
        try await eventually("已停用") { workspace.cue.now.quietLine == "已停用" }
        #expect(try await store.cueProfile()?.activeHost == nil)

        workspace.turnCue(true)
        try await eventually("回到 Mac Studio") { try await store.cueProfile()?.activeHost == "mac-old" }
        try await eventually("又在 Mac Studio 上运行") { workspace.cue.now.quietLine == "在「Mac Studio」上运行" }
    }
}
#endif
