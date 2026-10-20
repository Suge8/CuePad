#if os(macOS)
import CueStore
import CueSync
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 首次打开的接入面板：Cue 从没在哪台 Mac 上设过时自己弹一次，一处接入检测到的 Agent 并在这台启用 Cue，之后对 Cue 说的话直接交给它；
/// 一家能当 Cue 的都没装时给装法，装好回来就能启用；换新 Mac、还没和 iCloud 对过时不提议在这台启用，对过发现 Cue 在别处就只管接入；
/// 已接入只差 Cue 的老用户也弹一次，停用过 Cue 的不弹。
@MainActor
struct SetupTests {
    let app = TestApp()
    var services: AppServices { app.services }

    /// 同步报来这台的库和 iCloud 对没对过一遍（`SyncState.reconciled`）。
    private func sync(reconciled: Bool) async throws {
        app.sync.emit(SyncState(status: .idle, issues: [], reconciled: reconciled))
        try await eventually("对过一遍：\(reconciled)") { services.knowsSyncedFacts == reconciled }
    }

    /// 像启动时那样请工作区决定弹不弹（`AppDelegate` 同一个调用），再像面板打开时那样检测全部 Agent。
    private func launch(reconciled: Bool = true) async throws -> Workspace {
        services.startSync()
        try await sync(reconciled: reconciled)
        return await reopen()
    }

    /// 再打开一次（`relaunch` 之后）：弹不弹不看同步。
    private func reopen() async -> Workspace {
        let workspace = Workspace(services: services)
        workspace.offerSetup()
        await services.agents.redetect()
        return workspace
    }

    @Test func 首次打开_一键接入检测到的Agent并启用Cue_接着对Cue说的话交给它() async throws {
        try app.install(.pi)
        try app.install(.claudeCode)

        let first = try await launch()
        #expect(first.showsSetup)
        let agents = services.agents
        #expect(agents.connectable == [.pi, .claudeCode])
        #expect(first.setupCue == .enable)

        #expect(await first.setUp(connecting: agents.connectable, enablingCue: true).isEmpty)
        #expect(agents.status(.pi)?.isConnected == true && agents.status(.claudeCode)?.isConnected == true)
        #expect(try await services.store.cueProfile()?.hostID == TestApp.hostID)
        #expect(first.page == .cue)

        app.relaunch()
        let next = await reopen()
        #expect(!next.showsSetup)
        next.cue.draft = ComposerDraft(text: "整理发布说明")
        await next.sayToCue(from: Bindable(next.cue).draft)?.value  // 输入框的发送：没启用时这句会记成灵感
        #expect(try await services.store.cueMessages().map(\.text) == ["整理发布说明"])
    }

    @Test func 一家能当Cue的都没装_给装法_装好回来就能接入并启用() async throws {
        let workspace = try await launch()
        #expect(workspace.showsSetup)
        #expect(workspace.setupCue == .needsAgent)

        try app.install(.pi)
        await services.agents.redetect()  // 回到 App 时面板重新检测
        #expect(workspace.setupCue == .enable)
        #expect(await workspace.setUp(connecting: services.agents.connectable, enablingCue: true).isEmpty)
        #expect(try await services.store.cueProfile()?.enabledAt != nil)
    }

    @Test func 换新Mac_还没和iCloud对过_不提议在这台启用_对过发现Cue在别处就只管接入() async throws {
        try app.install(.pi)
        let workspace = try await launch(reconciled: false)
        #expect(workspace.showsSetup)
        #expect(workspace.setupCue == .waiting)

        let following = Task { await workspace.followCue() }
        defer { following.cancel() }
        _ = try await services.store.updateCueProfile { profile in  // 第一遍拉回来的：Cue 在原来那台上
            profile.hostID = "mac-old"
            profile.enabledAt = .now
        }
        try await sync(reconciled: true)
        try await eventually("Cue 那一行没了") { workspace.setupCue == .none }
        #expect(services.agents.connectable == [.pi])  // 接入照常
    }

    @Test func 老用户已接入Agent只差Cue_弹一次只剩Cue那一行_只这一次() async throws {
        try await app.connect(.pi)

        let first = try await launch()
        #expect(first.showsSetup)
        #expect(services.agents.connectable.isEmpty)
        #expect(first.setupCue == .enable)

        app.relaunch()
        #expect(await reopen().showsSetup == false)
    }

    @Test func 停用过Cue的_不弹() async throws {
        try await app.connect(.pi)
        let here = TestApp.hostID
        _ = try await services.store.updateCueProfile { $0.hostID = here }  // 启用过、又停用了：在哪台运行留着

        #expect(try await launch().showsSetup == false)
    }
}
#endif
