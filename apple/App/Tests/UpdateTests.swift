#if os(macOS)
import CuePi
import Foundation
import Testing
@testable import CuePad

/// Sparkle 自动更新：配置写在真实构建的 Info.plist 里，界面只经 `UpdateService` 操作更新器。
/// 更新要重启时不打断 CuePad 在后台托管、重启后会断（Claude Code、Codex 这类靠管道连着 App 的）、还在干活或等你确认的会话：
/// 等它们空下来再装，也可以现在就装。托管的 Pi 撑得过重启（新版经桥认回），它在干活不挡更新。
struct UpdateTests {
    @Test func 重启会断的托管会话在干活_等子代理或等你确认_更新等它们都空下来再装_托管的Pi在干活不等() async throws {
        let updater = FakeUpdater()
        let rig = TestApp(updater: updater)
        let updates = rig.services.updates
        let claude = rig.claude
        let working = claude.host("working", state: .thinking)
        let asking = claude.host("asking", state: .waitingForUser)
        // 自己这轮歇下、还在等子代理：托管的进程还有活
        let delegating = claude.host("delegating", state: .delegating)
        claude.host("resting", state: .settled)
        // 托管的 Pi 撑得过重启；终端里开的会话不受 CuePad 重启影响
        try await rig.host.connect("pi-hosted", cwd: "/work/p", busy: true, hosted: true)
        try await rig.host.connect("terminal", cwd: "/work/d", busy: true)

        updates.checkForUpdates()
        #expect(updater.installs == 0)
        #expect(updates.waitingFor == 3)

        claude.set(working, .settled)
        try await eventually("还等 2 个") { updates.waitingFor == 2 }
        claude.set(asking, .settled)
        try await eventually("还等 1 个") { updates.waitingFor == 1 }
        #expect(updater.installs == 0)

        claude.set(delegating, .settled)
        try await eventually("会断的都空下来就装") { updater.installs == 1 }
        #expect(updates.waitingFor == nil)
        #expect(rig.pi.sessions.first { $0.sessionID == "pi-hosted" }?.state.hasPendingWork == true)
    }

    @Test func 等着时点现在就装_立刻装_之后会话空下来不再装第二次() async throws {
        let updater = FakeUpdater()
        let rig = TestApp(updater: updater)
        let updates = rig.services.updates
        let working = rig.claude.host("working", state: .thinking)
        updates.checkForUpdates()
        #expect(updates.waitingNote == "等 1 个 Agent 做完再装")

        updates.installNow()
        #expect(updater.installs == 1)
        #expect(updates.waitingNote == nil)

        rig.claude.set(working, .settled)
        try await eventually("会话空下来") { rig.pi.sessions.first?.state == .settled }
        #expect(updater.installs == 1)
    }

    @Test func 真实构建里带着更新源地址与EdDSA公钥() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect((info["SUFeedURL"] as? String).flatMap(URL.init(string:))?.scheme == "https")
        let key = try #require(info["SUPublicEDKey"] as? String, "缺少 SUPublicEDKey")
        #expect(Data(base64Encoded: key)?.count == 32, "EdDSA 公钥应是 32 字节的 base64")
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    }

}
#endif
