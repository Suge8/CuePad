import AppKit
import Testing

@testable import CueDispatch

/// 用私有 NotificationCenter 投递激活通知，不切换真实前台。
@Suite struct WorkspaceAppsTests {
    private let me = NSRunningApplication.current
    private func activate(_ app: NSRunningApplication, on center: NotificationCenter) {
        center.post(
            name: NSWorkspace.didActivateApplicationNotification, object: nil,
            userInfo: [NSWorkspace.applicationUserInfoKey: app])
    }

    @Test func 激活通知更新上一个前台应用并唤醒订阅者() async {
        let center = NotificationCenter()
        let apps = WorkspaceApps(excludedPID: -1, notificationCenter: center)
        let stream = apps.activations()
        activate(me, on: center)
        var got: pid_t?
        for await pid in stream { got = pid; break }
        #expect(got == me.processIdentifier)
        #expect(apps.lastFrontmost()?.pid == me.processIdentifier)
    }

    @Test func CuePad自身激活时不成为投送目标() {
        let center = NotificationCenter()
        let apps = WorkspaceApps(excludedPID: me.processIdentifier, notificationCenter: center)
        activate(me, on: center)
        #expect(apps.lastFrontmost()?.pid != me.processIdentifier)
    }
}
