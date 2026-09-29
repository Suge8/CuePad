import AppKit
import Testing

@testable import CueDispatch

/// 用私有 NotificationCenter 投递激活通知，不切换真实前台。
/// 测试进程自身的 NSRunningApplication.current 没有有效 pid，改用一直在运行的 Finder 充当"别的应用"。
@Suite struct WorkspaceAppsTests {
    private func finder() throws -> NSRunningApplication {
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
    }

    private func activate(_ app: NSRunningApplication, on center: NotificationCenter) {
        center.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: app])
    }

    @Test func 激活通知更新上一个前台应用并唤醒订阅者() async throws {
        let finder = try finder()
        let center = NotificationCenter()
        let apps = WorkspaceApps(excludedPID: -1, notificationCenter: center)
        let stream = apps.activations()
        activate(finder, on: center)
        var got: pid_t?
        for await pid in stream { got = pid; break }
        #expect(got == finder.processIdentifier)
        #expect(apps.lastFrontmost()?.pid == finder.processIdentifier)
    }

    @Test func 被排除的应用激活时不成为投送目标() throws {
        let finder = try finder()
        let center = NotificationCenter()
        let apps = WorkspaceApps(excludedPID: finder.processIdentifier, notificationCenter: center)
        activate(finder, on: center)
        #expect(apps.lastFrontmost()?.pid != finder.processIdentifier)
    }
}
