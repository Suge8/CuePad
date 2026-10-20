import CueStore
import CueSync
import Observation
import UserNotifications
#if os(iOS)
import UIKit
#endif

/// 系统通知，两端一份：通知代理、通知权限、点开的通知去哪。点开时按种类路由（`AlertRoute`）：Agent 的打开那个会话（`pendingTap`，
/// 界面取走），Cue 的打开 Cue 页（`AppServices.pendingDeepLink = .cue`）。进程只有一个，由 App 代理持有并在启动完成前设为代理，
/// 冷启动时点开的通知才不会丢。
/// 你在不在看只有一条规则：开着这条提示说的那一页（会话页、Cue 页）就不提示。别的设备替你做决定（Mac 置手机推送标志、Mac 发通知）
/// 只认在线的 Mac 写下的（`CueStore.isWatched`）；手机自己前台收到推送时按本机此刻开着哪一页定。
/// - iOS：通知都是 CloudKit 订阅在服务端生成的锁屏通知；这里另管远程通知注册，设置页据此显示一行状态（`PiAlertStatus`）。
///   前台收到的 Agent 通知不展示（前台的提示是 App 内横幅，`SessionAlertTracker`）；Cue 的在 Cue 页不在屏上时照常弹。
/// - Mac：不收推送，通知都是这里发的本地通知（`post`）；你在哪台 Mac 上开着那一页时什么都不发，其余前台后台一样是系统通知。
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
        pushed()
        // Agent 的由 App 内横幅提示（开着那个会话时连横幅也不弹）；Cue 的没有 App 内横幅，这台手机开着 Cue 页就不弹（对话里已经看到了）
        return route == .cue && services?.cueViewers == 0 ? [.banner, .list, .sound] : []
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

/// 一条通知说的是什么：Agent 会话的提示（"等你"或"做完了"），或 Cue 的消息（带选项来问、urgent 的，都算"等你"）。
/// 手机的 CloudKit 推送与 Mac 的本地通知（`userInfo` 由这里写）都从 userInfo 认出。
nonisolated enum AlertRoute: Equatable {
    case session(PiAlertTap)
    case cue

    /// 用哪种提示的开关与提示音。
    var kind: PiAlert {
        switch self {
        case .session(let tap): tap.kind
        case .cue: .waitingForUser
        }
    }

    /// 说的是哪个会话（会话记录 id）；Cue 的为 nil。
    var session: UUID? {
        if case .session(let tap) = self { tap.sessionState } else { nil }
    }

    /// 开着哪一页就不用再说它（`CueStore.isWatched`）。
    var subject: AlertSubject { session.map(AlertSubject.session) ?? .cue }

    private static let subjectKey = "cuepad.alert", kindKey = "cuepad.alert.kind", recordKey = "cuepad.alert.record"
    private static let cueSubject = "cue", sessionSubject = "session"

    var userInfo: [AnyHashable: Any] {
        switch self {
        case .session(let tap): [Self.subjectKey: Self.sessionSubject, Self.kindKey: tap.kind.rawValue, Self.recordKey: tap.sessionState.uuidString]
        case .cue: [Self.subjectKey: Self.cueSubject]
        }
    }

    init?(userInfo: [AnyHashable: Any]) {
        switch userInfo[Self.subjectKey] as? String {
        case Self.cueSubject: self = .cue
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
