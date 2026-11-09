#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

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

        let toggle = CueSettingsModel()
        toggle.turn(false, here: services.hostID, services)
        try await eventually("已停用") { workspace.cue.now.quietLine == "已停用" }
        #expect(try await store.cueProfile()?.activeHost == nil)

        toggle.turn(true, here: services.hostID, services)
        try await eventually("回到 Mac Studio") { try await store.cueProfile()?.activeHost == "mac-old" }
        try await eventually("又在 Mac Studio 上运行") { workspace.cue.now.quietLine == "在「Mac Studio」上运行" }
    }
}
#endif
