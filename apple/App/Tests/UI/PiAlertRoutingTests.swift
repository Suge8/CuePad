import CueStore
import CueSync
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import CuePad
#if os(iOS)
import ObjectiveC
import UIKit
import Vision
#endif

/// 点开 Agent 的通知：直接打开触发它的那个会话；别的通知不改去处。点开的通知同链接一样交给工作区（`Workspace.openLinks`）。
struct PiAlertRoutingTests {
    let app = TestApp()

    /// 系统交来的通知交给这个 App（App 代理在打开资料库后接上，`AlertCenter.services`）。
    private func alertCenter() -> AlertCenter {
        let alerts = AlertCenter()
        alerts.services = app.services
        return alerts
    }

    /// 点开的这条通知说的是 `record` 那个会话：手机上是 CloudKit 查询订阅的推送，Mac 上是本机发的通知（`AlertRoute.userInfo`）。
    private func tapped(_ record: UUID) -> [AnyHashable: Any] {
        #if os(iOS)
        payload(subscription: "cuepad.pi.waiting", record: record)
        #else
        AlertRoute.session(PiAlertTap(kind: .waitingForUser, sessionState: record)).userInfo
        #endif
    }

    /// CloudKit 查询订阅通知的 userInfo（形状同 CueSync 的路由测试）。
    private func payload(subscription: String, record: UUID) -> [AnyHashable: Any] {
        [
            "aps": ["alert": ["loc-key": "pi_alert_waiting"]],
            "ck": ["ce": 2, "cid": "iCloud.com.example.cuepad", "nid": "n",
                   "qry": ["dbs": 1, "fo": 1, "rid": record.uuidString.lowercased(), "sid": subscription, "zid": "CuePad",
                           "zoid": "__defaultOwner__"]],
        ]
    }

    /// 手机推在正看着的页上（返回回到原处），Mac 换到那个会话页；别的通知不改去处。
    @Test func 点Pi通知_打开该会话_别的通知不改去处() async throws {
        try await PiStateRecorder(store: app.services.store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: "atlas")
        let session = try #require(try await app.services.store.allPiSessionStates().first)
        let alerts = alertCenter()
        let workspace = Workspace(services: app.services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        workspace.show(.project(Project.defaultID))

        alerts.receive(payload(subscription: "somebody.else", record: UUID()))
        #expect(app.services.pendingDeepLink == nil && workspace.top == .project(Project.defaultID))

        alerts.receive(tapped(session.id))
        try await eventually("打开那个会话") { workspace.top == .session(session.id) }

        #expect(workspace.shownSession == ViewerKeeper.Page(id: session.id, sessionID: "atlas"))
        #expect(app.services.pendingDeepLink == nil)
        #if os(iOS)
        #expect(workspace.root == .project(Project.defaultID))
        #endif
    }

    #if os(iOS)

    /// 会话页带着推入前读好的首帧推入后，点同一个会话的通知不再叠一页（路由身份只看会话 id）。
    @Test func 已在看的会话_点它的通知不重复推入() async throws {
        let id = UUID()
        let seed = PiSessionState(
            id: id, sessionID: "s", hostID: "mac", title: "s", projectID: nil, state: .known(.waitingForUser), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now, modifiedAt: .now)
        let alerts = alertCenter()
        let workspace = Workspace(services: app.services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        workspace.path = [.session(id, seed: SessionDigest(session: seed, project: nil, deliveries: []))]

        alerts.receive(payload(subscription: "cuepad.pi.waiting", record: id))
        try await eventually("工作区取走了通知") { app.services.pendingDeepLink == nil }

        #expect(workspace.path.count == 1)
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
        let alerts = alertCenter()
        let entry = unsafeBitCast(class_getMethodImplementation(AlertCenter.self, selector), to: Entry.self)
        let response = unsafeBitCast(Response(payload(subscription: "cuepad.pi.waiting", record: UUID())), to: UNNotificationResponse.self)

        let onMain = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let handler: @convention(block) () -> Void = { done.resume(returning: Thread.isMainThread) }
            entry(alerts, selector, .current(), response, handler)
        }

        #expect(onMain)
        #expect(app.services.pendingDeepLink != nil)
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
        let store = app.services.store
        try await PiStateRecorder(store: store, hostID: "mac-a").update(sessionID: "atlas", state: .settled, title: "atlas")
        let session = try #require(try await store.allPiSessionStates().first)
        let said = PiChatMessage(sessionID: "atlas", entryID: "u1", seq: 1, role: .user, text: "接口约定改成 v2", at: .now)
        try await store.writePiTranscript(PiTranscript(sessionID: "atlas", messages: [said], recap: PiRecap(pendingPrompt: said.text)))

        let alerts = alertCenter()
        alerts.receive(payload(subscription: "cuepad.pi.waiting", record: session.id))
        let window = try show(IOSRoot(services: app.services).environment(alerts))
        defer { window.isHidden = true }

        try await eventually("会话页显示对话") { try visibleText(in: window).contains("接口约定") }
    }
    #endif
}
