#if os(macOS)
import CuePi
import Foundation
import Testing
@testable import CuePad

/// Sparkle 自动更新：配置写在真实构建的 Info.plist 里，界面只经 `UpdateService` 操作更新器。
/// 更新要重启时不打断 CuePad 在后台托管、还在干活或等你确认的会话：等它们空下来再装，也可以现在就装。
struct UpdateTests {
    @Test func 后台托管的会话在干活或等你确认_更新等它们都空下来再装() async throws {
        let updater = FakeUpdater()
        let rig = TestApp(updater: updater)
        let updates = rig.services.updates
        let working = try await rig.host.connect("working", cwd: "/work/a", busy: true, hosted: true)
        let asking = try await rig.host.connect("asking", cwd: "/work/b", hosted: true)
        asking.setState(["kind": "waiting_user", "title": "允许使用 Bash？"])
        try await rig.host.connect("resting", cwd: "/work/c", hosted: true)
        // 终端里开的会话不受 CuePad 重启影响
        try await rig.host.connect("terminal", cwd: "/work/d", busy: true)
        try await eventually("asking 进入等你确认") { rig.pi.sessions.first { $0.sessionID == "asking" }?.state == .waitingForUser }

        updates.checkForUpdates()
        #expect(updater.installs == 0)
        #expect(updates.waitingFor == 2)

        working.setState(["kind": "idle"])
        try await eventually("还等 1 个") { updates.waitingFor == 1 }
        #expect(updater.installs == 0)

        asking.setState(["kind": "idle"])
        try await eventually("都空下来就装") { updater.installs == 1 }
        #expect(updates.waitingFor == nil)
    }

    @Test func 等着时点现在就装_立刻装_之后会话空下来不再装第二次() async throws {
        let updater = FakeUpdater()
        let rig = TestApp(updater: updater)
        let updates = rig.services.updates
        let working = try await rig.host.connect("working", cwd: "/work/a", busy: true, hosted: true)
        updates.checkForUpdates()
        #expect(updates.waitingNote == "等 1 个 Agent 做完再装")

        updates.installNow()
        #expect(updater.installs == 1)
        #expect(updates.waitingNote == nil)

        working.setState(["kind": "idle"])
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

    @Test func Sparkle框架随App嵌入() {
        let framework = Bundle.main.privateFrameworksURL?.appending(path: "Sparkle.framework")
        #expect(framework.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }
}
#endif
