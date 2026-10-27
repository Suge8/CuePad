#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 启用 Cue、改它运行的 Mac 只有一个入口（`AppServices.enableCue`），各处入口读同一处判断（`CueGate`）：
/// 这台的库还没和 iCloud 对过一遍时不能启用（不知道它是不是已在别的 Mac 上），Cue 那一行写在等什么；
/// 它正在别的 Mac 上运行时，没确认就不改，确认框说清改在哪台、原来那台不再运行，确认了才改过来；这台改不过来时原因写在那一行、仍在原来那台。
@MainActor
struct CueGateTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var store: CueStore { app.services.store }

    private func gate() async throws -> CueGate {
        try await CueSettings.read(from: store).gate(services)
    }

    /// 第一遍拉回来的：Cue 在 Mac Studio 上运行，那台醒着。
    private func runsOnStudio() async throws {
        try await store.recordMacAgents(host: "mac-old", name: "Mac Studio", [MacAgent(kind: .pi, model: nil, models: [])])
        try await store.recordMacPresence(host: "mac-old") { true }
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-old"
            profile.enabledAt = .now
        }
    }

    /// 设置里选这台：先请你确认（不动库），说清楚改在哪、哪台不再运行。
    private func chooseHere() async throws -> (CueSettingsModel, CueMove) {
        let model = CueSettingsModel()
        model.settings = try await CueSettings.read(from: store)
        let here = try #require(model.settings?.hosts(here: TestApp.hostID).first)
        model.choose(here, services)
        let move = try #require(model.moving)
        #expect(move.title == "让 Cue 改在这台 Mac 上运行？")
        #expect(move.message == "原来那台「Mac Studio」就不再运行 Cue。")
        #expect(move.confirm == "改在这台运行")
        #expect(try await store.cueProfile()?.activeHost == "mac-old")
        return (model, move)
    }

    @Test func 还没和iCloud对过_哪个入口都不能启用_Cue那一行写在等同步_对过后写它在哪台() async throws {
        try await app.connect(.pi)
        services.startSync()
        try await app.syncs(reconciled: false)
        let workspace = Workspace(services: services)
        let following = Task { await workspace.followCue() }
        defer { following.cancel() }

        #expect(try await gate() == .waiting("正在从 iCloud 同步…"))
        #expect(workspace.cue.now.quietLine == "正在从 iCloud 同步…")  // Cue 此刻（侧栏名片、菜单栏面板、小组件）：不说"还没启用"
        for moving in [false, true] {  // Cue 页的启用（`CueWelcome`）、接入面板、设置的选择器与改 Mac 的确认都调它
            await #expect(throws: CueEnableError.unsynced) { try await services.enableCue(on: TestApp.hostID, moving: moving) }
        }
        #expect(try await store.cueProfile()?.enabledAt == nil)

        try await runsOnStudio()
        try await app.syncs()
        try await eventually("Cue 此刻写它在哪台") { workspace.cue.now.quietLine == "在「Mac Studio」上运行" }
    }

    @Test func Cue在别的Mac上_确认框说清改在这台_确认了才改过来() async throws {
        try await app.connect(.pi)
        services.startSync()
        try await app.syncs()
        try await runsOnStudio()
        #expect(try await gate() == .runs(id: "mac-old", name: "Mac Studio"))

        let (model, move) = try await chooseHere()
        await #expect(throws: CueEnableError.runsElsewhere("Mac Studio")) { try await services.enableCue(on: TestApp.hostID, moving: false) }
        #expect(try await store.cueProfile()?.activeHost == "mac-old")

        model.moving = nil  // 确认框按下按钮先收起自己（`DialogCard.run`），再做按钮的事
        model.confirm(move, services)  // "改在这台运行"
        try await eventually("改在这台运行") { try await store.cueProfile()?.activeHost == TestApp.hostID }
        #expect(model.failure == nil)
    }

    @Test func Cue在别的Mac上_这台没有能当Cue的Agent_原因写在那一行_仍在原来那台() async throws {
        services.startSync()
        try await app.syncs()
        try await runsOnStudio()

        let (model, move) = try await chooseHere()
        model.moving = nil
        model.confirm(move, services)
        try await eventually("原因写在那一行") { model.failure != nil }
        #expect(model.failure == "没有能当 Cue 的 Agent：Pi 没装 · Claude Code 没装 · Codex 没装 · OpenCode 没装 · DeepSeek Harness 没装")
        #expect(try await store.cueProfile()?.activeHost == "mac-old")
    }
}
#endif
