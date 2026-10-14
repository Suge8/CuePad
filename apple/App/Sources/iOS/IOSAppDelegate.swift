#if os(iOS)
import UIKit
import UserNotifications

/// 通知代理必须在启动完成前设好，冷启动时点开的通知才不会丢。
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    let alerts = AlertCenter()

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = alerts
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
