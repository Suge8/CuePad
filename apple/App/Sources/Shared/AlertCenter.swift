import CueStore
import CueSync
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// 系统通知，两端一份：通知代理、通知权限、点开的通知去哪。点开时按种类路由（`AlertRoute`）：Agent 的打开那个会话（`pendingTap`，
/// 界面取走），Cue 的打开 Cue 页（`AppServices.pendingDeepLink = .cue`），周额度提醒只打开 App。进程只有一个，由 App 代理持有并在启动完成前设为代理，
/// 冷启动时点开的通知才不会丢。
/// 提示到不到你只有一条规则（`CueStore.reaches`：该不该你接、你在不在哪台在线的 Mac 上开着那一页）；手机自己前台收到推送时
/// 再按本机此刻开着哪一页定弹不弹。
/// - iOS：通知都是 CloudKit 订阅在服务端生成的锁屏通知；这里另管远程通知注册，设置页据此显示一行状态（`PiAlertStatus`）。
///   前台收到的 Agent 通知不展示（前台的提示是 App 内横幅，`SessionAlertTracker`）；Cue 的在 Cue 页不在屏上时照常弹。
/// - Mac：不收推送，通知都是这里发的本地通知（`post`）；你在哪台 Mac 上开着那一页时什么都不发，其余前台后台一样是系统通知。
/// - 周额度提醒（`remind`）两端都是本机排的定时本地通知：到点时 App 不必在跑，手机上也不靠推送。
@Observable
final class AlertCenter: NSObject, UNUserNotificationCenterDelegate {
    private(set) var pendingTap: PiAlertTap?
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// 点开的 Cue 通知交给它（`pendingDeepLink`）；资料库打开后接上（早于系统交来点开的通知）。
    @ObservationIgnored weak var services: AppServices?
    #if os(macOS)
    /// 主窗口：前台怎么呈现、你在不在看（`Workspace.presentation`）。
    @ObservationIgnored weak var workspace: Workspace?
    @ObservationIgnored let sounds = AlertSounds()
    /// Dock 角标该显示的数（`AppServices.startAlerts`）；没有权限时记着，开了之后补上。
    @ObservationIgnored var badge = 0
    #endif

    var isAuthorized: Bool { authorization == .authorized || authorization == .provisional }

    /// 用户可能在系统设置里改过：回到前台时重新读。
    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        #if os(macOS)
        await showBadge()
        #endif
    }

    /// 尚未决定时弹一次系统提示；已决定过的直接返回。
    func requestAuthorization() async {
        #if os(macOS)
        guard delivers else { return }
        #endif
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
        case .session(let tap): pendingTap = tap
        case .cue: services?.pendingDeepLink = .cue
        case .quota: break
        case nil: return
        }
        #if os(macOS)
        services?.windowShell?.show()
        #endif
    }

    func consumeTap() -> PiAlertTap? {
        defer { pendingTap = nil }
        return pendingTap
    }

    /// 系统回调：必须留在主 actor。async 的 @objc 代理方法由编译器生成转接，在方法所属的 executor 上调系统交来的完成块；
    /// 标成 nonisolated 时完成块在后台线程执行，UIKit 在里面断言主线程，点锁屏通知进 App 即崩溃。
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        receive(response.notification.request.content.userInfo)
    }

    /// 按最新的额度观测重排周额度提醒（`QuotaReminder`）：撤掉不再要响的待发提醒，要响的按同一标识加上（待发的原地换成最新的剩余）。
    /// Mac 第一次真要排时才征求权限（同 `post`）；手机的权限随推送一起征求（`enable`），没有就不排。
    func remind(_ quotas: [AccountQuota]) async {
        let center = UNUserNotificationCenter.current()
        let due = QuotaReminder.due(quotas, at: .now)
        let stale = await center.pendingNotificationRequests().map(\.identifier)
            .filter { id in id.hasPrefix(QuotaReminder.prefix) && !due.contains { $0.id == id } }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        guard !due.isEmpty else { return }
        #if os(macOS)
        guard delivers else {
            return AppServices.log.notice("周额度提醒（隔离库不排）：\(due.map { "\($0.title) @ \($0.fireAt)" }, privacy: .public)")
        }
        #endif
        await refresh()
        #if os(macOS)
        if authorization == .notDetermined { await requestAuthorization() }
        #endif
        guard isAuthorized else { return }
        for reminder in due {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.userInfo = AlertRoute.quota.userInfo
            content.threadIdentifier = QuotaReminder.prefix
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: reminder.fireAt.timeIntervalSinceNow, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
                AppServices.log.notice("周额度提醒排在 \(reminder.fireAt, privacy: .public)：\(reminder.title, privacy: .public)，\(reminder.body, privacy: .public)")
            } catch {
                AppServices.log.error("周额度提醒没能排上：\(String(describing: error), privacy: .public)")
            }
        }
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

    /// 幂等。只在有同步时调用：没有同步就不会有这类通知。尚未决定时请求一次权限（只会弹一次系统提示）。
    func enable() async {
        guard !enabled else { return }
        enabled = true
        await refresh()
        if authorization == .notDetermined, DebugHooks.asksNotificationPermission { await requestAuthorization() }
        // 无论是否授权都注册：同步区有变化的静默推送不要通知权限（`AlertSubscriptions.changesID`）
        UIApplication.shared.registerForRemoteNotifications()
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

/// 一条通知说的是什么：Agent 会话的提示（"等你"或"做完了"），Cue 的消息（带选项来问、urgent 的，都算"等你"），或周额度提醒。
/// 手机的 CloudKit 推送与本地通知（`userInfo` 由这里写）都从 userInfo 认出。
nonisolated enum AlertRoute: Equatable {
    case session(PiAlertTap)
    case cue
    case quota

    /// 用哪种提示的开关与提示音；周额度提醒没有开关（nil）。
    var kind: PiAlert? {
        switch self {
        case .session(let tap): tap.kind
        case .cue: .waitingForUser
        case .quota: nil
        }
    }

    /// 说的是哪个会话（会话记录 id）；Cue 的为 nil。
    var session: UUID? {
        if case .session(let tap) = self { tap.sessionState } else { nil }
    }

    /// 到不到你问 `CueStore.reaches` 时说的是什么；周额度提醒不看你在哪页（nil）。
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
            if let tap = PiAlertRoute.tap(from: userInfo) {
                self = .session(tap)
            } else if CueAlertRoute.message(from: userInfo) != nil {
                self = .cue
            } else {
                return nil
            }
        }
    }
}
