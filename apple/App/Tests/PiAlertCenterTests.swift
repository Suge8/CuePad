#if os(iOS)
import CueSync
import Foundation
import Testing
import UserNotifications
@testable import CuePad

/// Pi 通知到不了锁屏时，用户要能在设置里看到卡在哪一步、点一下去解决；App 在前台时照样提示，除非正看着那个会话。
@MainActor
struct PiAlertCenterTests {
    private func tap(_ session: UUID) -> PiAlertTap? {
        PiAlertRoute.tap(from: [
            "aps": ["alert": ["loc-key": "pi_alert_settled"]],
            "ck": ["ce": 2, "cid": "iCloud.com.sugeh.cuepad", "nid": "n",
                   "qry": ["dbs": 1, "fo": 1, "rid": session.uuidString.lowercased(), "sid": "cuepad.pi.settled", "zid": "CuePad",
                           "zoid": "__defaultOwner__"]],
        ])
    }

    @Test func 前台照样横幅_正看着那个会话时不提示() {
        let alerts = PiAlertCenter()
        let open = UUID()
        let other = UUID()
        alerts.beginViewing(open)

        #expect(alerts.presentation(of: tap(open)) == [])
        #expect(alerts.presentation(of: tap(other)).isSuperset(of: [.banner, .sound]))

        alerts.endViewing(open)
        #expect(alerts.presentation(of: tap(open)).contains(.banner))
    }

    @Test func 两个窗口都在看同一会话_关掉一个仍不提示() {
        let alerts = PiAlertCenter()
        let session = UUID()
        alerts.beginViewing(session)
        alerts.beginViewing(session)
        alerts.endViewing(session)
        #expect(alerts.presentation(of: tap(session)) == [])
    }

    typealias Case = (UNAuthorizationStatus, PiAlertCenter.Registration, PiAlertSubscriptionStatus, PiAlertStatus.State, PiAlertStatus.Action?)

    @Test(arguments: [
        (UNAuthorizationStatus.denied, PiAlertCenter.Registration.registered, PiAlertSubscriptionStatus.active, PiAlertStatus.State.problem, PiAlertStatus.Action.openSettings),
        (.notDetermined, .pending, .off, .problem, .allow),
        (.authorized, .registered, .active, .on, nil),
        (.provisional, .registered, .active, .on, nil),
        (.authorized, .pending, .off, .pending, nil),
        (.authorized, .failed("没有 aps-environment"), .off, .problem, nil),
        (.authorized, .registered, .failed("没有网络"), .problem, nil),
    ] as [Case])
    func 通知状态一行_写明卡在哪一步(_ c: Case) {
        let status = PiAlertStatus(authorization: c.0, registration: c.1, subscription: c.2)
        #expect(status.state == c.3)
        #expect(status.action == c.4)
        if case .failed(let reason) = c.1 { #expect(status.detail?.contains(reason) == true) }
        if case .failed(let reason) = c.2 { #expect(status.detail?.contains(reason) == true) }
    }
}
#endif
