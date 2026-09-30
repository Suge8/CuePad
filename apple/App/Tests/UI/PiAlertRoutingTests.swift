#if os(iOS)
import CueSync
import Foundation
import Testing
@testable import CuePad

/// 点开锁屏上的 Pi 通知：打开活动页并定位到触发它的会话；别的通知不改导航。
@MainActor
struct PiAlertRoutingTests {
    /// CloudKit 查询订阅通知的 userInfo（形状同 CueSync 的路由测试）。
    private func payload(subscription: String, record: UUID) -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["loc-key": "pi_alert_waiting"]],
            "ck": ["ce": 2, "cid": "iCloud.com.sugeh.cuepad", "nid": "n",
                   "qry": ["dbs": 1, "fo": 1, "rid": record.uuidString.lowercased(), "sid": subscription, "zid": "CuePad",
                           "zoid": "__defaultOwner__"]],
        ]
    }

    @Test(arguments: [Navigation.Layout.tabs, .split])
    func 点Pi通知_打开活动并定位到该会话(layout: Navigation.Layout) {
        let session = UUID()
        let alerts = PiAlertCenter()
        let navigation = Navigation()
        navigation.layout = layout
        navigation.projectsPath = [.today]

        alerts.receive(payload(subscription: "cuepad.pi.waiting", record: session))
        navigation.open(alert: alerts.consumeTap())

        #expect(navigation.focusedSession == session)
        switch layout {
        case .tabs: #expect(navigation.tab == .activity)
        case .split: #expect(navigation.panel == .activity)
        }
        #expect(alerts.consumeTap() == nil)
    }

    @Test func 别的通知_不改导航() {
        let alerts = PiAlertCenter()
        let navigation = Navigation()

        alerts.receive(payload(subscription: "somebody.else", record: UUID()))
        navigation.open(alert: alerts.consumeTap())

        #expect(navigation.tab == .projects)
        #expect(navigation.focusedSession == nil)
    }
}
#endif
