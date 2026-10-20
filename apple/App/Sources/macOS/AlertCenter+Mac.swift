#if os(macOS)
import CueStore
import CueSync
import UserNotifications
import os

/// Mac 的通知都是本机发的：Mac 不注册远程通知、不收 CloudKit 推送（docs/sync.md「Agent 与 Cue 的通知」），
/// 所以设置里的开关与提示音管得到每一条，免打扰只认系统的专注模式。
extension AlertCenter: CueNotifying {
    /// 隔离库（开发与验收）默认不发系统通知：通知权限、提示音与角标按 bundle id 记，与正式版同一个。
    /// Debug 构建给 `-CuePadNotifications YES` 时照常发（验收用，规则见 docs/verify.md「通知（Mac）」）。
    var delivers: Bool { services.map { !$0.location.isIsolated || DebugHooks.deliversNotifications } ?? false }

    func post(title: String, body: String) async {
        await post(AlertMessage(title: title, body: body))
    }

    /// 这条提示发不发（`post` 问）：到不到你（`reaches`），且这份库发系统通知（`delivers`）。
    func admits(_ alert: AlertMessage) async -> Bool {
        guard await reaches(alert.route) else { return false }
        guard delivers else {
            AppServices.log.notice("通知（隔离库不发）：\(alert.title, privacy: .public)：\(alert.body, privacy: .private)")
            return false
        }
        return true
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

    /// 这条提示此刻到不到你：这种提示开着，且 `AppServices.reaches`（这台 Mac 开着哪页也记在那里）；周额度提醒总是到。
    private func reaches(_ route: AlertRoute) async -> Bool {
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

    /// Dock 角标 = "等你"的总数；没有通知权限时不设（经通知中心设，受系统"标记"开关控制）。
    func showBadge(_ count: Int) async {
        badge = count
        await showBadge()
    }

    func showBadge() async {
        guard delivers, isAuthorized else { return }
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(badge)
        } catch {
            AppServices.log.error("Dock 角标没能更新：\(String(describing: error), privacy: .public)")
        }
    }
}
#endif
