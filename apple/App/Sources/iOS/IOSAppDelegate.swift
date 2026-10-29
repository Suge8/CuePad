#if os(iOS)
import AppIntents
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
        // 实时活动的"允许一次"在 App 进程里执行，可能是被叫到后台、没有窗口的时候：由这里答（`AllowOnceIntent`）
        AppDependencyManager.shared.add { self as any CueQuestionAnswering }
    }

    /// 资料库打不开时失败页的重试。
    func relaunch() {
        launch = Launch.make()
        connect()
    }

    private func connect() {
        guard case .ready(let services) = launch else { return }
        alerts.services = services
        services.alerts = alerts
    }

    func application(
        _ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = alerts
        CueAtlas.shared.load()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        alerts.registered()
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        alerts.registrationFailed(error)
    }

    /// 要紧的变化的推送（见 `AlertSubscriptions`：静默的与带 content-available 的可见通知，后台也会把 App 叫起来一会儿）：拉到推送说的变化再交还系统
    /// （冷启动时等同步启动完，见 `CloudSync.syncNow`）；交还前当场刷新小组件与角标，拉取失败如实返回。
    /// 回调返回后系统可能挂起，不依赖异步观察；远程实时活动由 Mac 经 APNs 更新，不在此用本地库覆盖。
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard case .ready(let services) = launch else { return .failed }
        return await services.refreshFromPush()
    }
}

extension IOSAppDelegate: CueQuestionAnswering {
    func answerCueQuestion(_ message: UUID, _ choice: String) async throws {
        guard case .ready(let services) = launch else { throw LibraryClosed() }
        try await services.answerRemoteCueQuestion(message, choice)
    }

    private struct LibraryClosed: LocalizedError {
        var errorDescription: String? { String(localized: "CuePad 的资料库没打开，到 App 里看看") }
    }
}
#endif
