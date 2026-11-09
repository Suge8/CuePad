import CueStore
import CueSync
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// 点开的通知按种类路由（`AlertRoute`），交给链接同一个入口（`AppServices.pendingDeepLink`）。进程只有一个，由 App 代理持有并在启动完成前设为代理，冷启动时点开的通知才不会丢。
/// 提示到不到你只有一条规则（`CueStore.reaches`）；手机自己前台收到推送时再按本机此刻开着哪一页定弹不弹。
/// - iOS：通知都是 CloudKit 订阅在服务端生成的锁屏通知，这里另管远程通知注册（`PiAlertStatus`）。
/// - Mac：不收推送，通知都是这里发的本地通知（`post`）。
/// - 周额度提醒（`remind`）两端都经 `post` 排成定时本地通知：到点时 App 不必在跑，手机上也不靠推送。
@Observable
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private var knownAuthorization: UNAuthorizationStatus?
    var authorization: UNAuthorizationStatus { knownAuthorization ?? .notDetermined }
    /// 点开的通知交给它（`pendingDeepLink`）；资料库打开后接上（早于系统交来点开的通知）。
    @ObservationIgnored weak var services: AppServices?
    #if os(macOS)
    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored let sounds = AlertSounds()
    #endif
    /// App 图标角标该显示的数（`CueNow.needsYou`），由 Mac 的 `AppDelegate`、iPhone 的 `AppServices.present` 给；没有权限时记着，开了之后补上。
    @ObservationIgnored private var badge = 0

    var isAuthorized: Bool { authorization == .authorized || authorization == .provisional }

    /// 不碰真实世界的（`LibraryLocation.touchesRealWorld`：测试、验收与装着正式版的 Mac 上的本机构建）默认不要通知权限、不发系统通知、不设角标：这些按 bundle id 记，与正式版同一个；
    /// 没人去点的权限弹窗还会一直留在系统里、盖住之后起的每个实例。Debug 构建给 `-CuePadNotifications YES` 时照常（docs/verify.md「通知」）。
    var delivers: Bool { services.map { $0.location.touchesRealWorld || DebugHooks.deliversNotifications } ?? false }

    /// 用户可能在系统设置里改过：回到前台、后台写角标时重新读。
    func refresh() async {
        knownAuthorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        await showBadge()
    }

    /// 经通知中心设，受系统"标记"开关控制，没有通知权限时不设。
    func showBadge(_ count: Int) async {
        badge = count
        guard delivers else { return }
        #if os(iOS)
        if UIApplication.shared.applicationState == .background { return await refresh() }
        #endif
        if knownAuthorization == nil { return await refresh() }
        await showBadge()
    }

    private func showBadge() async {
        guard delivers else { return }
        let center = UNUserNotificationCenter.current()
        guard isAuthorized else { return }
        do {
            try await center.setBadgeCount(badge)
        } catch {
            AppServices.log.error("App 图标角标没能更新：\(String(describing: error), privacy: .public)")
        }
    }

    func requestAuthorization() async {
        guard delivers else { return }
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            AppServices.log.error("通知权限请求失败：\(String(describing: error), privacy: .public)")
        }
        await refresh()
    }

    /// 点开的通知；不是 Agent 或 Cue 的通知则忽略。Mac 上同时把主窗口叫到前面。
    func receive(_ userInfo: [AnyHashable: Any]) {
        switch AlertRoute(userInfo: userInfo) {
        case .session(let tap): services?.pendingDeepLink = .session(tap.sessionState)
        case .cue: services?.pendingDeepLink = .cue
        case .quota: break
        case nil: return
        }
        #if os(macOS)
        services?.windowShell?.show()
        #endif
    }

    /// 系统回调：必须留在主 actor。async 的 @objc 代理方法由编译器生成转接，在方法所属的 executor 上调系统交来的完成块；
    /// 标成 nonisolated 时完成块在后台线程执行，UIKit 在里面断言主线程，点锁屏通知进 App 即崩溃。
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        receive(response.notification.request.content.userInfo)
    }

    /// 本机发通知的唯一出口：Mac 上到不到你不成立时、这份库不发时（`delivers`）什么都不做（不要权限、不装提示音）；第一次真要发时才征求权限，没有权限就不发。给了 `date` 是定时的：到点由系统弹，App 不必在跑；
    /// 同一 `id` 的待发通知原地换掉，已送达的还在通知中心里时系统只换内容、不再响（所以即时的每条标识都不同）。
    func post(_ alert: AlertMessage, id: String = UUID().uuidString, at date: Date? = nil) async {
        #if os(macOS)
        guard await reaches(alert.route) else { return }
        #endif
        guard delivers else {
            return AppServices.log.notice("通知（不碰真实世界，不发）：\(alert.title, privacy: .public)：\(alert.body, privacy: .private)")
        }
        if authorization == .notDetermined { await requestAuthorization() }
        guard isAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.userInfo = alert.route.userInfo
        content.threadIdentifier = alert.thread
        #if os(macOS)
        content.sound = await sound(for: alert.route)
        #else
        content.sound = .default
        #endif
        let trigger = date.map { UNTimeIntervalNotificationTrigger(timeInterval: $0.timeIntervalSinceNow, repeats: false) }
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        } catch {
            AppServices.log.error("通知没能发出：\(String(describing: error), privacy: .public)")
        }
    }

    func remind(_ quotas: [AccountQuota]) async {
        guard delivers else { return }
        let center = UNUserNotificationCenter.current()
        let due = QuotaReminder.due(quotas, at: .now)
        let stale = await center.pendingNotificationRequests().map(\.identifier)
            .filter { id in id.hasPrefix(QuotaReminder.prefix) && !due.contains { $0.id == id } }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        for reminder in due { await post(AlertMessage(reminder), id: reminder.id, at: reminder.fireAt) }
    }

    #if os(iOS)
    /// 手机收到推送（前台的 Agent、Cue 通知，后台的静默推送）：说明服务器上有新东西，这就拉一次，不等切一次后台。
    func pushed() {
        guard let services else { return }
        Task { await services.pull() }
    }
    #endif

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard let route = AlertRoute(userInfo: notification.request.content.userInfo) else { return [] }
        #if os(macOS)
        return await present(route)
        #else
        // Agent 的由 App 内横幅提示（开着那个会话时连横幅也不弹）；Cue 的没有 App 内横幅，这台手机开着 Cue 页就不弹（对话里已经看到了）
        switch route {
        case .quota: return [.banner, .list, .sound]
        case .cue:
            pushed()
            return services?.cueViewers == 0 ? [.banner, .list, .sound] : []
        case .session:
            pushed()
            return []
        }
        #endif
    }

    #if os(iOS)
    enum Registration: Equatable {
        case pending
        case registered
        case failed(String)
    }

    private(set) var registration: Registration = .pending
    @ObservationIgnored private var enabled = false

    /// 幂等。只在有同步时调用：没有同步就不会有这类通知。尚未决定时，等库里第一次有了 Mac（`CueStore.workMac`）才请求一次权限：
    /// 之前没有哪台会发来提示，新装一打开就弹系统提示，用户还不知道它要提示什么（设置里通知那一行随时能先开）。
    /// 只弹一次系统提示，不碰真实世界时不要（`delivers`）。
    func enable() async {
        guard !enabled, let services else { return }
        enabled = true
        await refresh()
        // 无论是否授权都注册：只叫醒 App 拉一次的静默推送（Cue 对你说的话、请求的结果，见 `AlertSubscriptions`）不要通知权限
        UIApplication.shared.registerForRemoteNotifications()
        guard authorization == .notDetermined else { return }
        services.follow(reporting: { .syncUnavailable(String(localized: "等 Mac 出现再请求通知权限没能启动：\(String(describing: $0))")) }) {
            for try await hasMac in services.store.observe({ try $0.workMac() != nil }) where hasMac {
                return await self.requestAuthorization()
            }
        }
    }

    func registered() { registration = .registered }

    /// 设置页的"重试"：重新向系统注册推送（订阅由同步顺带重试，见 `CloudSync.syncNow`）。
    func retryRegistration() {
        guard registration != .registered else { return }
        registration = .pending
        UIApplication.shared.registerForRemoteNotifications()
    }

    func registrationFailed(_ error: any Error) {
        AppServices.log.error("远程通知注册失败：\(String(describing: error), privacy: .public)")
        registration = .failed(error.localizedDescription)
    }
    #endif
}

struct AlertMessage {
    var route: AlertRoute
    var thread: String
    var title: String
    var body: String

    init(_ alert: SessionAlert) {
        let tap = PiAlertTap(kind: alert.kind, sessionState: alert.session)
        route = .session(tap)
        thread = tap.thread
        (title, body) = alert.content
    }

    init(title: String, body: String) {
        route = .cue
        thread = "cue"
        (self.title, self.body) = (title, body)
    }

    init(_ reminder: QuotaReminder) {
        route = .quota
        thread = QuotaReminder.prefix
        (title, body) = (reminder.title, reminder.body)
    }
}

/// Cue 的消息带选项来问、urgent 的，都算"等你"。手机的 CloudKit 推送与本地通知（`userInfo` 由这里写）都从 userInfo 认出。
nonisolated enum AlertRoute: Equatable {
    case session(PiAlertTap)
    case cue
    case quota

    /// 周额度提醒没有开关（nil）。
    var kind: PiAlert? {
        switch self {
        case .session(let tap): tap.kind
        case .cue: .waitingForUser
        case .quota: nil
        }
    }

    var session: UUID? {
        if case .session(let tap) = self { tap.sessionState } else { nil }
    }

    /// 周额度提醒不看你在哪页（nil）。
    var subject: AlertSubject? {
        switch self {
        case .session(let tap): .session(tap.sessionState, tap.kind)
        case .cue: .cue
        case .quota: nil
        }
    }

    private static let subjectKey = "cuepad.alert", kindKey = "cuepad.alert.kind", recordKey = "cuepad.alert.record"
    private static let cueSubject = "cue", sessionSubject = "session", quotaSubject = "quota"

    var userInfo: [AnyHashable: Any] {
        switch self {
        case .session(let tap): [Self.subjectKey: Self.sessionSubject, Self.kindKey: tap.kind.rawValue, Self.recordKey: tap.sessionState.uuidString]
        case .cue: [Self.subjectKey: Self.cueSubject]
        case .quota: [Self.subjectKey: Self.quotaSubject]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo[Self.subjectKey] as? String {
        case Self.cueSubject: self = .cue
        case Self.quotaSubject: self = .quota
        case Self.sessionSubject:
            guard let kind = (userInfo[Self.kindKey] as? String).flatMap(PiAlert.init(rawValue:)),
                let record = (userInfo[Self.recordKey] as? String).flatMap(UUID.init(uuidString:))
            else { return nil }
            self = .session(PiAlertTap(kind: kind, sessionState: record))
        default:
            switch CloudAlert(userInfo: userInfo) {
            case .session(let tap): self = .session(tap)
            case .cue: self = .cue
            case nil: return nil
            }
        }
    }
}
