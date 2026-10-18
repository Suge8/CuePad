#if os(iOS)
import CueStore
import Foundation
import ObjectiveC
import SwiftUI
import Testing
import UIKit
import Vision
import UserNotifications
@testable import CuePad

/// 点开锁屏上的 Pi 通知：直接打开触发它的那个会话的近况页；别的通知不改导航。
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

    /// 推在正看着的页上（返回回到原处）；iPhone 停在侧栏列表上时也推进去。
    @Test func 点Pi通知_打开该会话的近况() {
        let session = UUID()
        let alerts = AlertCenter()
        let navigation = Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, launchArguments: [:]))
        navigation.select(.unfiled)
        navigation.showList()

        alerts.receive(payload(subscription: "cuepad.pi.waiting", record: session))
        navigation.open(alert: alerts.consumeTap())

        #expect(navigation.root == .unfiled && navigation.path == [.session(session)])
        #expect(!navigation.showsAlert(about: session))  // 正看着它：前台不再弹它的提示
        #expect(alerts.consumeTap() == nil)
    }

    /// 会话页带着推入前读好的首帧推入后，点同一个会话的通知不再叠一页（路由身份只看会话 id）。
    @Test func 已在看的会话_点它的通知不重复推入() {
        let id = UUID()
        let seed = PiSessionState(
            id: id, sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(.waitingForUser), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now, modifiedAt: .now)
        let alerts = AlertCenter()
        let navigation = Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, launchArguments: [:]))
        navigation.path = [.session(id, seed: SessionDigest(session: seed, project: nil, deliveries: []))]

        alerts.receive(payload(subscription: "cuepad.pi.waiting", record: id))
        navigation.open(alert: alerts.consumeTap())

        #expect(navigation.path.count == 1)
    }

    @Test func 别的通知_不改导航() {
        let alerts = AlertCenter()
        let navigation = Navigation(settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!, launchArguments: [:]))

        alerts.receive(payload(subscription: "somebody.else", record: UUID()))
        navigation.open(alert: alerts.consumeTap())

        #expect(navigation.root == .cue && navigation.path.isEmpty)
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
        let alerts = AlertCenter()
        let entry = unsafeBitCast(class_getMethodImplementation(AlertCenter.self, selector), to: Entry.self)
        let response = unsafeBitCast(Response(payload(subscription: "cuepad.pi.waiting", record: UUID())), to: UNNotificationResponse.self)

        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let handler: @convention(block) () -> Void = { done.resume(returning: Thread.isMainThread) }
            entry(alerts, selector, .current(), response, handler)
        }

        #expect(onMain)
        #expect(alerts.pendingTap != nil)
    }

    // MARK: 点通知进会话页

    /// 在测试宿主的场景里挂一个真窗口，把整个 iPhone 界面放进去。
    private func show(_ root: some View) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        return window
    }

    /// 窗口此刻画出来的文字（对截图做文字识别）：用户看到什么就是什么；测试里读屏没开，SwiftUI 不生成读屏元素，只能这样读。
    private func visibleText(in window: UIWindow) throws -> String {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        try VNImageRequestHandler(cgImage: try #require(image.cgImage)).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// 冷启动点通知：点开的通知在界面建好之前就记下了，页面带着只有记录 id 的路由挂上，打开后要能读到对话。
    @Test func 点通知进会话页_对话显示出来() async throws {
        let app = TestApp()
        let store = app.services.store
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: "atlas")
        let session = try #require(try await store.allPiSessionStates().first)
        let said = PiChatMessage(sessionID: "atlas", entryID: "u1", seq: 1, role: .user, text: "接口约定改成 v2", at: .now)
        try await store.writePiTranscript(PiTranscript(sessionID: "atlas", messages: [said], recap: PiRecap(pendingPrompt: said.text)))

        let alerts = AlertCenter()
        alerts.receive(payload(subscription: "cuepad.pi.waiting", record: session.id))
        let window = try show(IOSRoot(services: app.services, alerts: alerts).environment(alerts))
        defer { window.isHidden = true }

        try await eventually("会话页显示对话") { try visibleText(in: window).contains("接口约定") }
    }
}
#endif
