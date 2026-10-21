#if os(macOS)
import CueStore
import CueSync
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 首次打开的接入面板：Cue 从没在哪台 Mac 上设过时自己弹一次，一处接入检测到的 Agent 并在这台启用 Cue，之后对 Cue 说的话直接交给它；
/// 能当 Cue 的一家都用不了时，推荐 Claude Code，一行一个按钮：安装（后台跑官方脚本）→ 登录（打开浏览器）→ 启用，没做成的就地写原因、可再点；
/// 换新 Mac、还没和 iCloud 对过时不提议在这台启用，对过发现 Cue 在别处就只管接入；已接入只差 Cue 的老用户也弹一次，停用过 Cue 的不弹。
@MainActor
struct SetupTests {
    let app = TestApp()
    var services: AppServices { app.services }

    /// 像启动时那样请工作区决定弹不弹（`AppDelegate` 同一个调用），再像面板打开时那样检测、问各家能不能用。
    private func launch(reconciled: Bool = true) async throws -> Workspace {
        services.startSync()
        try await app.syncs(reconciled: reconciled)
        return await reopen()
    }

    /// 再打开一次（`relaunch` 之后）：弹不弹不看同步。
    private func reopen() async -> Workspace {
        let workspace = Workspace(services: services)
        workspace.offerSetup()
        await workspace.recheckAgents()
        return workspace
    }

    /// 面板此刻的 Cue 那一行与 Agent 那几行（读这台写下的各家能不能用，同面板）。
    private func panel(_ workspace: Workspace) async throws -> (cue: Workspace.SetupCue, shown: [SetupRow], others: [SetupRow]) {
        let here = try await services.store.macAgents(on: TestApp.hostID)
        let rows = workspace.setupRows(here: here)
        return (workspace.setupCue(here: here), rows.shown, rows.others)
    }

    @Test func 首次打开_一键接入检测到的Agent并启用Cue_接着对Cue说的话交给它() async throws {
        try app.install(.pi)
        try app.install(.claudeCode)

        let first = try await launch()
        #expect(first.showsSetup)
        let agents = services.agents
        #expect(agents.connectable == [.pi, .claudeCode])
        #expect(try await panel(first).cue == .enable)

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

    @Test func 一家都没装_推荐ClaudeCode_安装登录启用三步() async throws {
        try app.offersClaudeInstaller()
        let workspace = try await launch()
        #expect(workspace.showsSetup)
        var now = try await panel(workspace)
        #expect(now.cue == .needsAgent)
        #expect(now.shown == [SetupRow(kind: .claudeCode, step: .install(nil))])
        #expect(now.others.map(\.kind) == [.codex, .pi])

        await workspace.installAgent(.claudeCode)
        now = try await panel(workspace)
        #expect(now.shown == [SetupRow(kind: .claudeCode, step: .logIn(nil))])

        await workspace.logIn(.claudeCode)
        now = try await panel(workspace)
        #expect(now.cue == .enable)
        #expect(now.shown == [SetupRow(kind: .claudeCode, step: .connect)])

        #expect(await workspace.setUp(connecting: [.claudeCode], enablingCue: true).isEmpty)
        #expect(try await services.store.cueProfile()?.runtime == .known(.claudeCode))
    }

    @Test func 装不上或没登录上_就地写原因_可再点() async throws {
        let workspace = try await launch()
        await workspace.installAgent(.claudeCode)  // 安装脚本出错
        guard case .install(let why?) = try await panel(workspace).shown.first?.step else {
            Issue.record("没装上时应仍是安装，带原因")
            return
        }
        #expect(why.contains("No such file"))

        try app.offersClaudeInstaller(loginFails: true)
        await workspace.installAgent(.claudeCode)
        await workspace.logIn(.claudeCode)
        #expect(try await panel(workspace).shown == [SetupRow(kind: .claudeCode, step: .logIn("没登录成功"))])
    }

    @Test func 换新Mac_还没和iCloud对过_不提议在这台启用_对过发现Cue在别处就只管接入() async throws {
        try app.install(.pi)
        let workspace = try await launch(reconciled: false)
        #expect(workspace.showsSetup)
        #expect(try await panel(workspace).cue == .waiting("正在从 iCloud 同步…"))

        let following = Task { await workspace.followCue() }
        defer { following.cancel() }
        _ = try await services.store.updateCueProfile { profile in  // 第一遍拉回来的：Cue 在原来那台上
            profile.hostID = "mac-old"
            profile.enabledAt = .now
        }
        try await app.syncs()
        try await eventually("Cue 那一行没了") { try await panel(workspace).cue == .none }
        #expect(try await panel(workspace).shown == [SetupRow(kind: .pi, step: .connect)])  // 接入照常
    }

    @Test func 老用户已接入Agent只差Cue_弹一次只剩Cue那一行_只这一次() async throws {
        try await app.connect(.pi)

        let first = try await launch()
        #expect(first.showsSetup)
        let now = try await panel(first)
        #expect(now.shown.isEmpty)
        #expect(now.cue == .enable)

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
