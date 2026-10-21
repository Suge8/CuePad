#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 启用 Cue、换它运行的 Mac 只有一个入口（`AppServices.enableCue`），各处入口读同一处判断（`CueGate`）：
/// 这台的库还没和 iCloud 对过一遍时不能启用（不知道它是不是已在别的 Mac 上）；它正在别的 Mac 上运行时，没确认就不换，确认了才换过来。
@MainActor
struct CueGateTests {
    let app = TestApp()
    var services: AppServices { app.services }
    var store: CueStore { app.services.store }

    private func gate() async throws -> CueGate {
        try await CueSettings.read(from: store).gate(services)
    }

    @Test func 还没和iCloud对过_哪个入口都不能启用() async throws {
        try await app.connect(.pi)
        services.startSync()
        try await app.syncs(reconciled: false)

        #expect(try await gate() == .waiting("正在从 iCloud 同步…"))
        for moving in [false, true] {  // 启用卡、接入面板、设置的选择器与换过去的确认都调它
            await #expect(throws: CueEnableError.unsynced) { try await services.enableCue(on: TestApp.hostID, moving: moving) }
        }
        #expect(try await store.cueProfile()?.enabledAt == nil)
    }

    @Test func Cue在别的Mac上_没确认不换_确认了才换过来() async throws {
        try await app.connect(.pi)
        services.startSync()
        try await app.syncs()
        try await store.recordMacAgents(host: "mac-old", name: "Mac Studio", [MacAgent(kind: .pi, model: nil, models: [])])
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "mac-old"
            profile.enabledAt = .now
        }

        let model = CueSettingsModel()
        model.settings = try await CueSettings.read(from: store)
        #expect(model.settings?.gate(services) == .runs(id: "mac-old", name: "Mac Studio"))
        let here = try #require(model.settings?.hosts(here: TestApp.hostID).first)
        model.choose(here, services)  // 设置里选这台：先请你确认，不动库
        #expect(model.moving == here)
        #expect(try await store.cueProfile()?.activeHost == "mac-old")

        await #expect(throws: CueEnableError.runsElsewhere("Mac Studio")) { try await services.enableCue(on: TestApp.hostID, moving: false) }
        #expect(try await store.cueProfile()?.activeHost == "mac-old")

        try await services.enableCue(on: TestApp.hostID, moving: true)  // 确认框的"换过去"
        #expect(try await store.cueProfile()?.activeHost == TestApp.hostID)
    }
}
#endif
