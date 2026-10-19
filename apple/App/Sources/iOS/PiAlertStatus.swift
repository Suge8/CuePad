#if os(iOS)
import CueSync
import UserNotifications

/// 设置页里通知的那一行：从系统权限、远程通知注册、服务端订阅三步里找出卡在哪，并给出能解决它的动作。
/// 三步缺一不可，任何一步不通锁屏都收不到提示，所以每一步的失败都要写明，不能静默。
/// `detail` 是给人看的说明；底层原因（错误码、服务端说明）只放 `diagnostics`，界面折叠着给，排查时再展开。
struct PiAlertStatus: Equatable {
    enum State { case on, pending, problem }
    enum Action { case allow, openSettings, retry }

    let state: State
    let title: String
    let detail: String?
    let diagnostics: String?
    let action: Action?

    init(authorization: UNAuthorizationStatus, registration: AlertCenter.Registration, subscription: PiAlertSubscriptionStatus) {
        switch (authorization, registration, subscription) {
        case (.denied, _, _):
            self = Self(.problem, "通知已关闭", "Agent 在等你确认或做完时，锁屏收不到提示。", action: .openSettings)
        case (.notDetermined, _, _):
            self = Self(.problem, "还没有开启通知", "开启后，Agent 在等你确认或做完时，锁屏会提示你。", action: .allow)
        case (_, .failed(let reason), _):
            self = Self(.problem, "没能向系统注册推送", Self.retrying, diagnostics: reason, action: .retry)
        case (_, _, .failed(let reason)):
            self = Self(.problem, "没能向 iCloud 登记通知", Self.retrying, diagnostics: reason, action: .retry)
        case (_, .registered, .active):
            self = Self(.on, "已开启", "Agent 在等你确认或做完时，锁屏会提示你。")
        default:
            self = Self(.pending, "正在开启…", nil)
        }
    }

    private static let retrying = "Agent 的锁屏通知暂时收不到。回到前台时会自动重试，也可以现在重试。"

    private init(_ state: State, _ title: String, _ detail: String?, diagnostics: String? = nil, action: Action? = nil) {
        self.state = state
        self.title = title
        self.detail = detail
        self.diagnostics = diagnostics
        self.action = action
    }
}
#endif
