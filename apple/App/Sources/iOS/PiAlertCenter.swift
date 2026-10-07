#if os(iOS)
import CueSync
import Observation
import UIKit
import UserNotifications

/// 锁屏上的 Pi 通知（CloudKit 订阅由服务端直接生成）：征得通知权限、注册远程通知，把点开的通知交给界面
/// （打开活动页并定位到该会话），前台时决定要不要弹横幅。进程只有一个，由 `IOSAppDelegate` 持有。
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
    /// 正显示着的会话近况页（会话记录 id → 窗口数，iPad 可能多个窗口）：这些会话的通知不弹，人就在看。
    @ObservationIgnored private var viewing: [UUID: Int] = [:]

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

    func beginViewing(_ session: UUID) { viewing[session, default: 0] += 1 }

    func endViewing(_ session: UUID) {
        guard let count = viewing[session] else { return }
        viewing[session] = count > 1 ? count - 1 : nil
    }

    /// 前台收到通知时怎么显示：照样横幅与声音（用户可能正看着别的页面），正看着触发它的那个会话时不弹。
    func presentation(of tap: PiAlertTap?) -> UNNotificationPresentationOptions {
        if let tap, viewing[tap.sessionState] != nil { return [] }
        return [.banner, .list, .sound]
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let tap = PiAlertRoute.tap(from: notification.request.content.userInfo)
        return await MainActor.run { presentation(of: tap) }
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

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        alerts.registered()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        alerts.registrationFailed(error)
    }
}
#endif
