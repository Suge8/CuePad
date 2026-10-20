#if os(iOS)
import Observation
import UIKit
import UserNotifications

/// 通知代理必须在启动完成前设好，冷启动时点开的通知才不会丢。
/// 进程唯一的资料库与服务（`Launch`）也在这里建：代理随进程建出、早于启动完成，与窗口无关；静默推送把 App 冷启动到后台时
/// 系统不一定建窗口，挂在窗口上的服务就拿不到，推送只能空手返回、让系统把这次唤醒白白挂起。
@Observable
final class IOSAppDelegate: NSObject, UIApplicationDelegate {
    @ObservationIgnored let alerts = AlertCenter()
    private(set) var launch: Launch

    override init() {
        launch = Launch.make()
        super.init()
        connect()
    }

    /// 资料库打不开时失败页的重试。
    func relaunch() {
        launch = Launch.make()
        connect()
    }

    /// 实时活动的"允许一次"也在这里接上：它在 App 进程里执行，可能是被叫到后台、没有窗口的时候。
    private func connect() {
        guard case .ready(let services) = launch else { return CueActivityAnswer.answer = nil }
        alerts.services = services
        CueActivityAnswer.answer = { try await services.answerCueQuestion($0, $1) }
    }

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

    /// 同步区有变化的静默推送与带 content-available 的等你类推送（后台也会把 App 叫起来一会儿）：拉到推送说的变化再交还系统
    /// （冷启动时等同步启动完，见 `AppServices.pull`）；拉到的变化经快照那条观察改实时活动（`CueLiveActivity`）。
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard case .ready(let services) = launch else { return .noData }
        await services.pull()
        return .newData
    }
}
#endif
