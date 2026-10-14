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

    /// 同步区有变化的静默推送（后台也会把 App 叫起来一会儿）：拉一次再交还系统。
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await alerts.services?.pullForPush()
        return .newData
    }
}
#endif
