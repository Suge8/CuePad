#if os(macOS)
import CueStore
import CueSync
import UserNotifications
import os

/// Mac 的通知都是本机发的：Mac 不注册远程通知、不收 CloudKit 推送（docs/sync.md「Agent 与 Cue 的通知」），
/// 所以设置里的开关与提示音管得到每一条，免打扰只认系统的专注模式。
extension AlertCenter: CueNotifying {
    func post(title: String, body: String) async {
        await post(AlertMessage(title: title, body: body))
    }

    /// 提示音（`post` 问）：这种提示选的那段（先装进去，见 `AlertSounds`），选了无声为 nil；没有开关的周额度提醒用系统默认音。
    func sound(for route: AlertRoute) async -> UNNotificationSound? {
        guard let kind = route.kind else { return .default }
        guard let sound = services?.settings.alerts[kind].sound else { return nil }
        return UNNotificationSound(named: await sounds.prepare(sound))
    }

    /// CuePad 在前台时系统要呈现一条通知：发出之后才关掉这种提示、才开着那一页的，不呈现；其余同后台，系统横幅加声音
    /// （遵守专注模式）。不在窗口里另出提示条：macOS 27 实测前台回复里只要带 `.sound`，系统照样弹横幅。
    func present(_ route: AlertRoute) async -> UNNotificationPresentationOptions {
        await reaches(route) ? [.banner, .sound, .list] : []
    }

    /// 这条提示此刻到不到你（`post` 问）：这种提示开着，且 `AppServices.reaches`（这台 Mac 开着哪页也记在那里）；周额度提醒总是到。
    func reaches(_ route: AlertRoute) async -> Bool {
        guard let kind = route.kind, let subject = route.subject else { return true }
        guard let services = workspace?.services, services.settings.alerts[kind].isOn else { return false }
        return await services.reaches(subject)
    }

    /// 打开了这个会话：撤掉它那一组已送达的通知（每条标识不同，按路由认）。
    func dismiss(session: UUID) async {
        guard delivers else { return }
        let center = UNUserNotificationCenter.current()
        let shown = await center.deliveredNotifications()
            .filter { AlertRoute(userInfo: $0.request.content.userInfo)?.session == session }
            .map(\.request.identifier)
        if !shown.isEmpty { center.removeDeliveredNotifications(withIdentifiers: shown) }
    }
}
#endif
