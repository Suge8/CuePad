#if os(iOS)
import CueSync
import Observation
import UIKit
import UserNotifications

/// 锁屏上的 Pi 通知（CloudKit 订阅由服务端直接生成）：征得通知权限、注册远程通知，把点开的通知交给界面
/// （打开活动页并定位到该会话）。App 在前台时系统不展示通知：前台的提示是 App 内的横幅（`SessionAlertTracker`，
/// 由同步来的会话状态驱动，不依赖推送是否到达），后台才是系统通知。进程只有一个，由 `IOSAppDelegate` 持有。
/// 权限与注册结果都留在这里，设置页据此显示一行状态（`PiAlertStatus`）。
@MainActor @Observable
final class PiAlertCenter: NSObject, UNUserNotificationCenterDelegate {
    enum Registration: Equatable {
        case pending
        case registered
        case failed(String)
    }

    private(set) var pendingTap: PiAlertTap?
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    private(set) var registration: Registration = .pending
    @ObservationIgnored private var enabled = false

    /// 幂等。只在有同步时调用：没有同步就不会有这类通知。尚未决定时请求一次权限（只会弹一次系统提示）。
    func enable() async {
        guard !enabled else { return }
        enabled = true
        await refresh()
        if authorization == .notDetermined { await requestAuthorization() }
        // 无论是否授权都注册：CloudKit 同步本身也靠推送
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// 用户可能在系统设置里改过：回到前台时重新读。
    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppServices.log.error("通知权限请求失败：\(String(describing: error), privacy: .public)")
        }
        await refresh()
    }

    func registered() { registration = .registered }

    /// 设置页的"重试"：重新向系统注册推送（订阅由同步引擎重试，见 `AppServices.syncNow`）。
    func retryRegistration() {
        guard registration != .registered else { return }
        registration = .pending
        UIApplication.shared.registerForRemoteNotifications()
    }

    func registrationFailed(_ error: any Error) {
        AppServices.log.error("远程通知注册失败：\(String(describing: error), privacy: .public)")
        registration = .failed(error.localizedDescription)
    }

    /// 点开的通知；不是 Pi 通知则忽略。
    func receive(_ userInfo: [AnyHashable: Any]) {
        if let tap = PiAlertRoute.tap(from: userInfo) { pendingTap = tap }
    }

    func consumeTap() -> PiAlertTap? {
        defer { pendingTap = nil }
        return pendingTap
    }

    /// 系统回调：必须留在主 actor。async 的 @objc 代理方法由编译器生成转接，在方法所属的 executor 上调系统交来的完成块；
    /// 标成 nonisolated 时完成块在后台线程执行，UIKit 在里面断言主线程，点锁屏通知进 App 即崩溃。
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        receive(response.notification.request.content.userInfo)
    }

    /// 前台收到的通知不展示：同一件事由 App 内横幅提示（正看着那个会话时连横幅也不弹）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [] }
}

/// 通知代理必须在启动完成前设好，冷启动时点开的通知才不会丢。
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    let alerts = PiAlertCenter()

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = alerts
        DebugHooks.launched(alerts: alerts)
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        alerts.registered()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        alerts.registrationFailed(error)
    }
}
#endif
