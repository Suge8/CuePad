#if os(macOS)
import Foundation
import Testing
@testable import CuePad

/// 记录调用的更新器替身。
final class FakeUpdater: AppUpdater {
    var automaticallyChecksForUpdates = true
    var canCheckForUpdates = true
    private(set) var checks = 0
    func checkForUpdates() { checks += 1 }
}

/// Sparkle 自动更新：配置写在真实构建的 Info.plist 里，界面只经 `UpdateService` 操作更新器。
@MainActor
struct UpdateTests {
    @Test func 真实构建里带着更新源地址与EdDSA公钥() throws {
        let info = Bundle.main.infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://cue-pad.com/appcast.xml")
        let key = try #require(info["SUPublicEDKey"] as? String, "缺少 SUPublicEDKey")
        #expect(Data(base64Encoded: key)?.count == 32, "EdDSA 公钥应是 32 字节的 base64")
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    }

    @Test func Sparkle框架随App嵌入() {
        let framework = Bundle.main.privateFrameworksURL?.appending(path: "Sparkle.framework")
        #expect(framework.map { FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func 自动检查开关与立即检查转给更新器() {
        let updater = FakeUpdater()
        let service = UpdateService(updater: updater)
        #expect(service.isAvailable)
        #expect(service.automaticallyChecks)

        service.automaticallyChecks = false
        #expect(!updater.automaticallyChecksForUpdates)
        #expect(!service.automaticallyChecks)

        service.checkForUpdates()
        #expect(updater.checks == 1)
    }

    @Test func 更新器正忙时不可检查() {
        let updater = FakeUpdater()
        updater.canCheckForUpdates = false
        #expect(!UpdateService(updater: updater).canCheckForUpdates)
    }

    @Test func 没有更新器时_隔离模式_全部无操作而不崩溃() {
        let service = UpdateService(updater: nil)
        #expect(!service.isAvailable && !service.canCheckForUpdates && !service.automaticallyChecks)
        service.automaticallyChecks = true
        service.checkForUpdates()
        #expect(!service.automaticallyChecks)
    }

    @Test func 主菜单有检查更新项() throws {
        let app = try #require(MainMenu.build().items.first?.submenu)
        let item = try #require(app.items.first { $0.title == "检查更新…" })
        #expect(item.action == #selector(AppDelegate.checkForUpdates(_:)))
    }
}
#endif
