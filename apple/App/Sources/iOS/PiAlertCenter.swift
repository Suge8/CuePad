#if os(iOS)
import CueSync
import Observation
import UIKit
import UserNotifications

/// 锁屏上的 Pi 通知（CloudKit 订阅由服务端直接生成）：征得通知权限、注册远程通知，
/// 把点开的通知交给界面（打开活动页并定位到该会话）。进程只有一个，由 `IOSAppDelegate` 持有。
@MainActor @Observable
final class PiAlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private(set) var pendingTap: PiAlertTap?
    @ObservationIgnored private var enabled = false

    /// 幂等。只在有同步时调用：没有同步就不会有这类通知。
    func enable() async {
        guard !enabled else { return }
        enabled = true
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppServices.log.notice("通知权限请求失败：\(String(describing: error), privacy: .public)")
        }
        // 无论是否授权都注册：CloudKit 同步本身也靠推送
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// 点开的通知；不是 Pi 通知则忽略。
    func receive(_ userInfo: [AnyHashable: Any]) {
        if let tap = PiAlertRoute.tap(from: userInfo) { pendingTap = tap }
    }

    func consumeTap() -> PiAlertTap? {
        defer { pendingTap = nil }
        return pendingTap
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let tap = PiAlertRoute.tap(from: response.notification.request.content.userInfo) else { return }
        await MainActor.run { pendingTap = tap }
    }

    /// App 在前台时照样横幅提示（用户可能正看着别的页面）。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// 通知代理必须在启动完成前设好，冷启动时点开的通知才不会丢。
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    let alerts = PiAlertCenter()

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = alerts
        return true
    }
}
#endif
