import CueSync
import SwiftUI

/// 同步状态给人看的一句话、补充说明与图标（Mac 与 iOS 设置共用）。颜色只表达含义：正常是墨，需要处理是注意色，出错是失败色。
struct SyncSummary: Equatable {
    enum Tone { case normal, attention, failure }

    let title: String
    let detail: String?
    let symbol: String
    let tone: Tone

    init(_ status: SyncStatus) {
        switch status {
        case .starting: (title, detail, symbol, tone) = ("正在连接 iCloud…", nil, "icloud", .normal)
        // 没有在同步是这台设备的情况（没有 iCloud 权限、隔离库），不是出错
        case .unavailable(let reason): (title, detail, symbol, tone) = ("没有在同步", reason, "icloud.slash", .attention)
        case .idle: (title, detail, symbol, tone) = ("已同步", nil, "checkmark.icloud", .normal)
        case .syncing: (title, detail, symbol, tone) = ("正在同步…", nil, "arrow.triangle.2.circlepath.icloud", .normal)
        case .noAccount:
            (title, detail, symbol, tone) = ("iCloud 没有开启", Self.turnOnICloud, "icloud.slash", .attention)
        case .accountRestricted:
            (title, detail, symbol, tone) = ("iCloud 账号受限", "家长控制或设备管理限制了 iCloud，本机数据照常可用", "lock.icloud", .attention)
        case .accountUnavailable:
            (title, detail, symbol, tone) = ("iCloud 暂时不可用", "稍后会自动重试", "exclamationmark.icloud", .attention)
        case .quotaExceeded:
            (title, detail, symbol, tone) = ("iCloud 空间不足", "本机改动都已保留，空间释放后自动上传", "exclamationmark.icloud", .attention)
        case .needsDecision(let decision):
            (title, detail, symbol, tone) = ("同步已暂停，需要你决定", Self.describe(decision), "pause.circle", .attention)
        // 底层原因（错误码、服务端说明）在设置的「没能同步」明细里按记录列出，状态这里只说人话
        case .failed: (title, detail, symbol, tone) = ("同步出错", Self.failedDetail, "xmark.icloud", .failure)
        }
    }

    func color(_ palette: Palette) -> Color {
        switch tone {
        case .normal: palette.ink2
        case .attention: palette.attention
        case .failure: palette.failure
        }
    }

    #if os(macOS)
    static let failedDetail = "有记录没能上传，本机的内容都在，会自动重试"
    #else
    static let failedDetail = "有记录没能上传，本机的内容都在。回到前台会自动重试，也可以点立即同步"
    #endif

    /// 没登录 iCloud 或关掉了本 App 的 iCloud 时，去哪开。
    #if os(macOS)
    static let turnOnICloud = "在「系统设置 › Apple 账户 › iCloud」里登录，并在使用 iCloud 的 App 里打开 CuePad；打开后自动开始同步，本机数据不受影响"
    #else
    static let turnOnICloud = "在「设置 › 你的名字 › iCloud › 使用 iCloud 的 App」里打开 CuePad（没登录 iCloud 时先登录）；打开后自动开始同步，本机数据不受影响"
    #endif

    private static func describe(_ decision: SyncDecision) -> String {
        switch decision {
        case .accountSwitched: "iCloud 账号换了，本机数据属于上一个账号"
        case .cloudDataDeleted: "iCloud 里的 CuePad 数据被删除了"
        case .cloudDataReset: "iCloud 里的 CuePad 数据被重置了"
        }
    }
}

extension SyncIssue {
    /// "没能同步"明细里一条的人话：哪一类记录没能同步；底层原因（`message`）折在它下面。
    var summary: String {
        switch recordType {
        case "cards": "一张灵感或任务没能同步"
        case "projects": "一个项目没能同步"
        case "sendRecords": "一条发送记录没能同步"
        case "attachments": "一张图片没能同步"
        case "piSessionStates", "piMessages": "Agent 会话的内容没能同步"
        case "deliveryRequests": "一条发给 Mac 的请求没能同步"
        case "directoryBindings": "项目的代码目录没能同步"
        default: "同步遇到一个问题"
        }
    }
}

nonisolated extension SyncStatus {
    /// 此刻同步能把请求送到 Mac、把 Mac 上的 Pi 状态带回来：已连上或正在连接。
    /// 其余状态（没开 iCloud、不可用、暂停、出错、空间不足）都到不了，界面写明原因。
    var reachesMac: Bool {
        switch self {
        case .starting, .idle, .syncing: true
        default: false
        }
    }
}

extension AppServices {
    /// 发给 Pi 会话的请求（回复、作答、重发）此刻送得到执行它的 Mac：手机靠同步；Mac 上就是本机执行，总送得到。
    var reachesPiHost: Bool {
        #if os(iOS)
        #if DEBUG
        // 演示 Mac（-CuePadDemoMac）就在本机库里接手，隔离模式没有同步也送得到
        if DebugScene.defaults.bool(forKey: "CuePadDemoMac") { return true }
        #endif
        return syncStatus.reachesMac
        #else
        true
        #endif
    }
}
