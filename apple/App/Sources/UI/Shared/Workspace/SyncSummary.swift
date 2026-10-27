import CueStore
import CueSync
import SwiftUI

/// 同步状态给人看的一句话、补充说明、图标与要不要你注意（`StatusTone`，颜色由它定）；Mac 与 iOS 共用。
nonisolated struct SyncSummary: Equatable {
    let title: String
    let detail: String?
    let icon: Icon
    let tone: StatusTone

    /// 一行写完：标题，有说明时接在冒号后（手机上到不了 Mac 时 Cue 的欢迎卡）。
    var line: String { detail.map { String(localized: "\(title)：\($0)") } ?? title }

    init(_ status: SyncStatus) {
        switch status {
        case .starting: (title, detail, icon, tone) = (String(localized: "正在连接 iCloud…"), nil, .syncStarting, .calm)
        // 没有在同步是这台设备的情况（没有 iCloud 权限、隔离库），不是出错
        case .unavailable(let reason): (title, detail, icon, tone) = (String(localized: "没有在同步"), reason, .syncOff, .notice)
        case .idle: (title, detail, icon, tone) = (String(localized: "已同步"), nil, .synced, .calm)
        case .syncing: (title, detail, icon, tone) = (String(localized: "正在同步…"), nil, .syncing, .calm)
        case .offline: (title, detail, icon, tone) = (String(localized: "连不上 iCloud"), String(localized: "没有网络或 iCloud 暂时不通；本机改动都在，连上后自动上传"), .syncOff, .notice)
        case .noAccount:
            (title, detail, icon, tone) = (String(localized: "iCloud 没有开启"), Self.turnOnICloud, .syncOff, .notice)
        case .accountRestricted:
            (title, detail, icon, tone) = (String(localized: "iCloud 账号受限"), String(localized: "家长控制或设备管理限制了 iCloud，本机数据照常可用"), .syncRestricted, .notice)
        case .accountUnavailable:
            (title, detail, icon, tone) = (String(localized: "iCloud 暂时不可用"), String(localized: "稍后会自动重试"), .syncTrouble, .notice)
        case .quotaExceeded:
            (title, detail, icon, tone) = (String(localized: "iCloud 空间不足"), String(localized: "本机改动都已保留，空间释放后自动上传"), .syncTrouble, .notice)
        case .needsDecision(let decision):
            (title, detail, icon, tone) = (String(localized: "同步已暂停，需要你决定"), Self.describe(decision), .syncPaused, .notice)
        case .outdated: (title, detail, icon, tone) = (String(localized: "这台的 CuePad 要更新"), Self.updateToSync, .syncPaused, .notice)
        // 是哪些、为什么在设置的「没能同步」明细里逐条说（`SyncIssue.text`），原话折在详情里
        case .failed: (title, detail, icon, tone) = (String(localized: "同步出错"), Self.failedDetail, .failure, .failure)
        }
    }

    #if os(macOS)
    static let failedDetail = String(localized: "有改动没能同步，本机的内容都在；每一条为什么、会不会自动重试，点「查看」")
    #else
    static let failedDetail = String(localized: "有改动没能同步，本机的内容都在；每一条为什么、会不会自动重试，见下面的明细")
    #endif

    /// 别的设备用着这台跟不上的新版时（`SyncStatus.outdated`）：只在同步那一行说，后面给去更新的钮（`updateTitle`）；会话与 Cue 页不再各说一遍。
    static let updateToSync = String(localized: "别的设备已用新版，这台更新后接着同步；这期间写下的都在，更新后自动发出")
    #if os(macOS)
    static let updateTitle = String(localized: "检查更新…")
    #else
    static let updateTitle = String(localized: "在 TestFlight 里更新")
    /// 打开 TestFlight（列表里 CuePad 那一行有更新钮）。只经 TestFlight 发布，没有 App Store 页。
    static let update = URL(string: "itms-beta://")!
    #endif

    /// 没开 iCloud（`SyncStatus.noAccount`）时给的出路：打开系统设置。Mac 直达 Apple 账户那一页；iOS 只能打开设置里这个 App 的那一页，再照 `turnOnICloud` 走。
    #if os(macOS)
    static let settingsTitle = String(localized: "打开系统设置")
    static let settings = URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!
    #else
    static let settingsTitle = String(localized: "打开设置")
    static let settings = URL(string: UIApplication.openSettingsURLString)!
    #endif

    /// 没登录 iCloud 或关掉了本 App 的 iCloud 时，去哪开。
    #if os(macOS)
    static let turnOnICloud = String(localized: "在「系统设置 › Apple 账户 › iCloud」里登录，并在使用 iCloud 的 App 里打开 CuePad；打开后自动开始同步，本机数据不受影响")
    #else
    static let turnOnICloud = String(localized: "在「设置 › 你的名字 › iCloud › 使用 iCloud 的 App」里打开 CuePad（没登录 iCloud 时先登录）；打开后自动开始同步，本机数据不受影响")
    #endif

    private static func describe(_ decision: SyncDecision) -> String {
        switch decision {
        case .accountSwitched: String(localized: "iCloud 账号换了，本机数据属于上一个账号")
        case .cloudDataDeleted: String(localized: "iCloud 里的 CuePad 数据被删除了")
        case .cloudDataReset: String(localized: "iCloud 里的 CuePad 数据被重置了")
        }
    }
}

extension SyncIssue {
    /// "没能同步"明细里一条的人话，只由归类（`problem`）推出：哪一样、出了什么事、会自己好还是要你做什么。原话（`detail`）折在它下面的详情里。
    var text: String {
        switch problem {
        case .refused where kind == .request: String(localized: "iCloud 没接受这次同步，会自动重试")
        case .refused: String(localized: "\(subject)没被 iCloud 收下，会自动重试")
        case .local where kind == .incoming: String(localized: "\(subject)没能存进这台设备，已跳过")
        case .local: String(localized: "这台设备的资料库读写出错，会自动重试")
        // 构造不出来的只在这次运行里不再重试（`SyncCoordinator.unsendable`），改过或下次打开再试
        case .fileMissing: String(localized: "\(subject)的文件不在这台设备上，传不上去；下次打开 CuePad 会再试，还不行就重新添加它")
        // 跳过的这条令牌已越过，更新后也不会补拉，只有之后的同类内容能同步
        case .unknownType: String(localized: "收到一条更新版本的 CuePad 写的内容，这版认不出，已跳过；更新这台后，之后的同类内容就能同步")
        case .damaged: String(localized: "收到一张损坏的图片，已跳过")
        }
    }

    private var subject: String {
        switch recordType.flatMap(Table.init(rawValue:)) {
        case .cards: String(localized: "一张灵感或任务")
        case .projects: String(localized: "一个项目")
        case .sendRecords: String(localized: "一条发送记录")
        case .attachments: String(localized: "一张图片")
        case .piSessionStates, .piMessages: String(localized: "Agent 会话的内容")
        case .deliveryRequests: String(localized: "一条发给 Mac 的请求")
        case .directoryBindings: String(localized: "项目的文件夹")
        case .agentCatalogs: String(localized: "一个 Agent 的模型与命令")
        case .previews: String(localized: "Agent 发来的一份内容")
        case .accountQuotas: String(localized: "订阅额度")
        case .cueMessages: String(localized: "和 Cue 的一条对话")
        case .cueLines: String(localized: "Cue 记忆里的一条")
        case .cueProfile: String(localized: "Cue 的设置")
        case .cueState: String(localized: "Cue 此刻的状态")
        case .cueRead: String(localized: "Cue 页读到的位置")
        case .macPresence: String(localized: "一台 Mac 在不在线")
        case .macAgents: String(localized: "一台 Mac 上能用的 Agent 清单")
        case .sessionViewers: String(localized: "一台设备开着哪一页")
        case .agentLibraries: String(localized: "一台 Mac 上的技能与规则")
        case .agentLibraryFiles: String(localized: "一台 Mac 上一份技能或规则的正文")
        // 本机表不同步，认不出的是更新版本的表
        case nil, .piSessions, .projectDirectories, .cueSummaries, .writeCounter, .syncRecords: String(localized: "一条记录")
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

/// Mac 设置里同步那一行此刻怎么说：说哪种状态、图标位置转不转圈。
struct ShownSync: Equatable {
    let status: SyncStatus
    let busy: Bool
    var summary: SyncSummary { SyncSummary(status) }
}

extension AppServices {
    /// Mac 设置那一行（`SyncRow`）用。`lasting`：这一轮同步中（`.syncing`，一批上传或拉积压）已久过 `Pending.delay`（经 `pending` 给）。没久过的照旧说已同步：
    /// 每传一句都要零点几秒，一闪一下"正在同步…"比稍等更扰人（同 `Pending`）。正在连接从第一帧就是它，照说；立即同步是你按的，当场转圈。
    func shownSync(lasting: Bool) -> ShownSync {
        syncStatus == .syncing && !lasting ? ShownSync(status: .idle, busy: isSyncingNow) : ShownSync(status: syncStatus, busy: isSyncBusy)
    }

    /// 要当场生效的请求（停止、改名、补对话）此刻送得到执行它的 Mac：手机靠同步；Mac 上就是本机执行，总送得到。
    /// 说的话（回复、作答、开会话、交给 Agent、重发）不看它：写下就排着，恢复后自动发出，同对 Cue 说的话。
    var reachesPiHost: Bool {
        #if os(iOS)
        speech.reachableSince != nil  // 演示 Mac 在本机库里接手时一直算通（`SpeechClock`）
        #else
        true
        #endif
    }
}
