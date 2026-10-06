#if os(iOS)
import CueSync
import UserNotifications

/// 设置页里 Pi 通知的一行：从系统权限、远程通知注册、服务端订阅三步里找出卡在哪，并给出能解决它的动作。
/// 三步缺一不可，任何一步不通锁屏都收不到提示，所以每一步的失败都要写明，不能静默。
struct PiAlertStatus: Equatable {
    enum State { case on, pending, problem }
    enum Action { case allow, openSettings }

    let state: State
    let title: String
    let detail: String?
    let action: Action?

    init(authorization: UNAuthorizationStatus, registration: PiAlertCenter.Registration, subscription: PiAlertSubscriptionStatus) {
        switch (authorization, registration, subscription) {
        case (.denied, _, _):
            self = Self(.problem, "通知已关闭", "Pi 在等你确认或做完时，锁屏收不到提示。", .openSettings)
        case (.notDetermined, _, _):
            self = Self(.problem, "还没有开启通知", "开启后，Pi 在等你确认或做完时，锁屏会提示你。", .allow)
        case (_, .failed(let reason), _):
            self = Self(.problem, "没能注册推送", reason, nil)
        case (_, _, .failed(let reason)):
            self = Self(.problem, "通知订阅没能建立", "\(reason)。回到前台时会重试。", nil)
        case (_, .registered, .active):
            self = Self(.on, "已开启", "Pi 在等你确认或做完时，锁屏会提示你。", nil)
        default:
            self = Self(.pending, "正在开启…", nil, nil)
        }
    }

    private init(_ state: State, _ title: String, _ detail: String?, _ action: Action?) {
        self.state = state
        self.title = title
        self.detail = detail
        self.action = action
    }
}
#endif
