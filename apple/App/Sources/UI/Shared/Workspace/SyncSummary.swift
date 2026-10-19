import CueSync
import SwiftUI

/// 同步状态给人看的一句话、补充说明、图标与要不要你注意（`StatusTone`，颜色由它定）；Mac 与 iOS 共用。
nonisolated struct SyncSummary: Equatable {
    let title: String
    let detail: String?
    let icon: Icon
    let tone: StatusTone

    init(_ status: SyncStatus) {
        switch status {
        case .starting: (title, detail, icon, tone) = ("正在连接 iCloud…", nil, .syncStarting, .calm)
        // 没有在同步是这台设备的情况（没有 iCloud 权限、隔离库），不是出错
        case .unavailable(let reason): (title, detail, icon, tone) = ("没有在同步", reason, .syncOff, .notice)
        case .idle: (title, detail, icon, tone) = ("已同步", nil, .synced, .calm)
        case .syncing: (title, detail, icon, tone) = ("正在同步…", nil, .syncing, .calm)
        case .offline: (title, detail, icon, tone) = ("连不上 iCloud", "没有网络或 iCloud 暂时不通；本机改动都在，连上后自动上传", .syncOff, .notice)
        case .noAccount:
            (title, detail, icon, tone) = ("iCloud 没有开启", Self.turnOnICloud, .syncOff, .notice)
        case .accountRestricted:
            (title, detail, icon, tone) = ("iCloud 账号受限", "家长控制或设备管理限制了 iCloud，本机数据照常可用", .syncRestricted, .notice)
        case .accountUnavailable:
            (title, detail, icon, tone) = ("iCloud 暂时不可用", "稍后会自动重试", .syncTrouble, .notice)
        case .quotaExceeded:
            (title, detail, icon, tone) = ("iCloud 空间不足", "本机改动都已保留，空间释放后自动上传", .syncTrouble, .notice)
        case .needsDecision(let decision):
            (title, detail, icon, tone) = ("同步已暂停，需要你决定", Self.describe(decision), .syncPaused, .notice)
        // 底层原因（错误码、服务端说明）在设置的「没能同步」明细里按记录列出，状态这里只说人话
        case .failed: (title, detail, icon, tone) = ("同步出错", Self.failedDetail, .failure, .failure)
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
        case "directoryBindings": "项目的文件夹没能同步"
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

#if os(iOS)
extension AppServices {
    /// 同步到不了 Mac 时（`SyncStatus.reachesMac`）给人看的那一句；送得到时为 nil。手机与 iPad 上设置那一行（侧栏、项目页末尾）
    /// 与 iPhone 底部项目那一格带的点都只读它，点的颜色按它的 `tone`。
    var macAlert: SyncSummary? {
        let status = syncStatus
        return status.reachesMac ? nil : SyncSummary(status)
    }
}
#endif

extension AppServices {
    /// 发给 Pi 会话的请求（回复、作答、重发）此刻送得到执行它的 Mac：手机靠同步；Mac 上就是本机执行，总送得到。
    var reachesPiHost: Bool {
        #if os(iOS)
        speech.reachableSince != nil  // 演示 Mac 在本机库里接手时一直算通（`SpeechClock`）
        #else
        true
        #endif
    }
}
