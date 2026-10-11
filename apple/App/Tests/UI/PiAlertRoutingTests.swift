#if os(iOS)
import CueStore
import CueSync
import Foundation
import ObjectiveC
import Testing
import UserNotifications
@testable import CuePad

/// 点开锁屏上的 Pi 通知：直接打开触发它的那个会话的近况页；别的通知不改导航。
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
    func 点Pi通知_打开该会话的近况(layout: Navigation.Layout) {
        let session = UUID()
        let alerts = PiAlertCenter()
        let navigation = Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, launchArguments: [:]))
        navigation.layout = layout
        navigation.projectsPath = [.unfiled]

        alerts.receive(payload(subscription: "cuepad.pi.waiting", record: session))
        navigation.open(alert: alerts.consumeTap())

        switch layout {
        case .tabs:
            #expect(navigation.tab == .agent)
            #expect(navigation.agentPath == [.session(session)])
        case .split:
            #expect(navigation.splitPath.last == .session(session))
        }
        #expect(alerts.consumeTap() == nil)
    }

    /// 会话页带着推入前读好的首帧推入后，点同一个会话的通知不再叠一页（路由身份只看会话 id）。
    @Test func 已在看的会话_点它的通知不重复推入() {
        let id = UUID()
        let seed = PiSessionState(
            id: id, sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(.waitingForUser), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now, modifiedAt: .now)
        let alerts = PiAlertCenter()
        let navigation = Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, launchArguments: [:]))
        navigation.layout = .split
        navigation.splitPath = [.session(id, seed: SessionDigest(session: seed, project: nil, deliveries: []))]

        alerts.receive(payload(subscription: "cuepad.pi.waiting", record: id))
        navigation.open(alert: alerts.consumeTap())

        #expect(navigation.splitPath.count == 1)
    }

    @Test func 别的通知_不改导航() {
        let alerts = PiAlertCenter()
        let navigation = Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, launchArguments: [:]))

        alerts.receive(payload(subscription: "somebody.else", record: UUID()))
        navigation.open(alert: alerts.consumeTap())

        #expect(navigation.tab == .projects)
        #expect(navigation.agentPath.isEmpty)
        #expect(navigation.splitPath.isEmpty)
    }

    /// 系统（UIKit）交来的完成块只能在主线程调用，否则抛异常崩溃（真机点锁屏通知进 App 的崩溃）。
    /// 像系统一样经 Objective-C 选择器调用代理：完成块必须在主线程执行，点开的通知也已记下。
    @Test func 系统回调的完成块在主线程调用() async {
        nonisolated final class Response: NSObject {
            @objc let notification: NSObject
            init(_ userInfo: [AnyHashable: Any]) { notification = Delivered(userInfo) }
        }
        nonisolated final class Delivered: NSObject {
            @objc let request: UNNotificationRequest
            init(_ userInfo: [AnyHashable: Any]) {
                let content = UNMutableNotificationContent()
                content.userInfo = userInfo
                request = UNNotificationRequest(identifier: "t", content: content, trigger: nil)
            }
        }
        typealias Entry = @convention(c) (AnyObject, Selector, UNUserNotificationCenter, UNNotificationResponse, @convention(block) () -> Void) -> Void
        let selector = NSSelectorFromString("userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:")
        let alerts = PiAlertCenter()
        let entry = unsafeBitCast(class_getMethodImplementation(PiAlertCenter.self, selector), to: Entry.self)
        let response = unsafeBitCast(Response(payload(subscription: "cuepad.pi.waiting", record: UUID())), to: UNNotificationResponse.self)

        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let handler: @convention(block) () -> Void = { done.resume(returning: Thread.isMainThread) }
            entry(alerts, selector, .current(), response, handler)
        }

        #expect(onMain)
        #expect(alerts.pendingTap != nil)
    }
}
#endif
