#if os(macOS)
import CueStore
import CueSync
import UserNotifications
import os

extension AlertCenter: CueNotifying {
    func post(title: String, body: String) async {
        await post(AlertMessage(title: title, body: body))
    }

    func sound(for route: AlertRoute) async -> UNNotificationSound? {
        guard services?.settings.sounds == true else { return nil }
        guard let kind = route.kind else { return .default }
        return UNNotificationSound(named: await sounds.prepare(Sound(kind.tone)))
    }

    /// CuePad 在前台时系统要呈现一条通知：发出之后才关掉这种提示、才开着那一页的，不呈现；其余同后台，系统横幅加声音
    /// （遵守专注模式）。不在窗口里另出提示条：macOS 27 实测前台回复里只要带 `.sound`，系统照样弹横幅。
    func present(_ route: AlertRoute) async -> UNNotificationPresentationOptions {
        await reaches(route) ? [.banner, .sound, .list] : []
    }

    func reaches(_ route: AlertRoute) async -> Bool {
        guard let kind = route.kind, let subject = route.subject else { return true }
        guard let services = workspace?.services, services.settings.alerts[kind] else { return false }
        return await services.reaches(subject)
    }
}
#endif
