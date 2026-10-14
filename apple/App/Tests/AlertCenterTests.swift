#if os(iOS)
import CueSync
import Foundation
import Testing
import UserNotifications
@testable import CuePad

/// Pi 通知到不了锁屏时，用户要能在设置里看到卡在哪一步、点一下去解决。前台的提示是 App 内横幅（见 `SessionNoticeTests`）。
struct AlertCenterTests {
    typealias Case = (
        UNAuthorizationStatus, AlertCenter.Registration, PiAlertSubscriptionStatus, PiAlertStatus.State, PiAlertStatus.Action?, String?
    )

    @Test(arguments: [
        (UNAuthorizationStatus.denied, AlertCenter.Registration.registered, PiAlertSubscriptionStatus.active, PiAlertStatus.State.problem, PiAlertStatus.Action.openSettings, nil),
        (.notDetermined, .pending, .off, .problem, .allow, nil),
        (.authorized, .registered, .active, .on, nil, nil),
        (.provisional, .registered, .active, .on, nil, nil),
        (.authorized, .pending, .off, .pending, nil, nil),
        (.authorized, .failed("没有 aps-environment"), .off, .problem, .retry, "没有 aps-environment"),
        (.authorized, .registered, .failed("CKErrorDomain 错误 4"), .problem, .retry, "CKErrorDomain 错误 4"),
    ] as [Case])
    func 通知状态一行_写明卡在哪一步(_ c: Case) {
        let status = PiAlertStatus(authorization: c.0, registration: c.1, subscription: c.2)
        #expect(status.state == c.3)
        #expect(status.action == c.4)
        #expect(status.diagnostics == c.5)
        // 底层原因只放进可展开的详情，不混进给人看的说明
        if let reason = c.5 { #expect(status.detail?.contains(reason) != true && !status.title.contains(reason)) }
    }
}
#endif
