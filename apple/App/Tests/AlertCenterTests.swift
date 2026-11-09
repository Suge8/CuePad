#if os(iOS)
import CueSync
import Foundation
import Testing
import UserNotifications
@testable import CuePad

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
        (.authorized, .registered, .offline, .pending, nil, nil),
    ] as [Case])
    func 通知状态一行_写明卡在哪一步(_ c: Case) {
        let status = PiAlertStatus(authorization: c.0, registration: c.1, subscription: c.2)
        #expect(status.state == c.3)
        #expect(status.action == c.4)
        #expect(status.diagnostics == c.5)
        if let reason = c.5 { #expect(status.detail?.contains(reason) != true && !status.title.contains(reason)) }
    }
}
#endif
