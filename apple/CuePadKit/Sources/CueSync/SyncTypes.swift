import CloudKit
import Foundation

/// 对外的同步状态，界面直接显示。本机数据在任何状态下都完好，可继续使用。
public enum SyncStatus: Equatable, Sendable {
  /// 正在连接 iCloud：同步刚开始，还没确认账号状态。
  case starting
  /// 空闲（已同步，或尚无可同步的内容）。
  case idle
  case syncing
  /// 未登录 iCloud。
  case noAccount
  /// iCloud 账号受限（家长控制或设备管理）。
  case accountRestricted
  /// 账号暂时不可用或无法确定，稍后会自动重试。
  case accountUnavailable
  /// iCloud 空间不足：本机改动保留并继续待推送，空间释放后自动恢复。
  case quotaExceeded
  /// 需要用户决定如何处理本机数据后才会继续同步，见 `SyncDecision`。
  case needsDecision(SyncDecision)
  /// 出现了未预期的失败（描述给用户看，详情在 `issues`）；下一次本机改动会重试。
  case failed(String)
  /// 这台设备没有在同步（原因给用户看）：没有同步（隔离模式、构建没有 iCloud 权限）或同步没能启动。由 App 层设置。
  case unavailable(String)
}

/// 同步暂停、等用户决定的原因。
public enum SyncDecision: Equatable, Sendable {
  /// iCloud 账号换了：本机数据属于上一个账号。
  case accountSwitched
  /// 云端数据被删除（用户在 iCloud 设置里清除了 CuePad 数据）。
  case cloudDataDeleted
  /// 云端数据被重置（清除或加密数据重置），云端已没有之前的记录。
  case cloudDataReset
}

public enum SyncResolution: Sendable {
  /// 保留本机数据，作为全新内容上传到当前账号的云端。
  case uploadLocal
  /// 丢弃本机的同步数据（卡片、项目、任务、附件等），从当前账号的云端重新开始。
  case eraseLocal
}

public enum SyncError: Error, Equatable, Sendable {
  case nothingToResolve
}

extension SyncError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .nothingToResolve: "没有需要处理的同步决定"
    }
  }
}

/// 同步过程中遇到的、被跳过或没能处理的事项（未知记录类型、损坏的附件、单条记录写入失败等）。不静默。
public struct SyncIssue: Equatable, Sendable {
  public var recordType: String?
  public var recordName: String?
  public var message: String

  public init(recordType: String? = nil, recordName: String? = nil, message: String) {
    self.recordType = recordType
    self.recordName = recordName
    self.message = message
  }
}

extension Error {
  /// 写进日志的原因：CloudKit 错误取错误码、服务器的说明（`localizedDescription` 常只剩"错误 14"，说明在 userInfo 的文字项里，
  /// 如 `ServerErrorDescription`）与建议的重试间隔；整个 `description` 带记录内容，不进日志。
  var brief: String {
    guard let error = self as? CKError else { return localizedDescription }
    let reasons = error.errorUserInfo.sorted { $0.key < $1.key }.compactMap { key, value in (value as? String).map { "\(key)=\($0)" } }
    let retry = error.retryAfterSeconds.map { "，\($0) 秒后重试" } ?? ""
    return "\(error.code.rawValue) \(error.code)" + (reasons.isEmpty ? "" : " " + reasons.joined(separator: "，")) + retry
  }

  /// 给人排查用的完整原因：CloudKit 被服务端拒绝时 `localizedDescription` 常只剩"错误 N"，服务端说明与底层错误在 `description` 里。
  var diagnosis: String { "\(localizedDescription)（\(self)）" }
}

/// Pi 锁屏通知的服务端订阅（只有 iOS 建立）是否就绪。
public enum PiAlertSubscriptionStatus: Equatable, Sendable {
  /// 这台设备不建立订阅（Mac），或还没尝试。
  case off
  case active
  /// 没能建立（完整原因，见 `Error.diagnosis`）；每次回到前台、账号变化时重试。
  case failed(String)
}

/// 界面订阅的同步快照：状态与最近的问题一起给出，任一变化都送达。
public struct SyncState: Equatable, Sendable {
  public var status: SyncStatus
  public var issues: [SyncIssue]
  public var alerts: PiAlertSubscriptionStatus

  public init(status: SyncStatus, issues: [SyncIssue], alerts: PiAlertSubscriptionStatus = .off) {
    self.status = status
    self.issues = issues
    self.alerts = alerts
  }
}

/// 拉取器、发送者与账号检查交给协调器的事件（测试直接构造）。
enum CloudEvent: Sendable {
  case accountStatus(CKAccountStatus)
  /// 此刻登录的账号（用户记录名）
  case account(String)
  /// 拉取时同步区不在了（`deletedByUser`：你在 iCloud 设置里删了 CuePad 的数据）
  case zoneMissing(deletedByUser: Bool)
  /// 发送者开始、结束一轮上传
  case sending(Bool)
  /// 拉取器开始、结束按版本对账（没有令牌时那一遍）
  case catchingUp(Bool)
  case fetched(modifications: [CKRecord], deletions: [(id: CKRecord.ID, recordType: String)])
  case sent(SentRecords)
}

/// 一批上传之后发送者怎么接着做。
struct SendOutcome: Sendable {
  /// 有记录被收下，或被拒的已处理好（带上了服务器的版本标签等），接着发下一批不会原样再被拒
  var progressed: Bool
  /// 配额、登录或未预期的失败：先停下，等下一次明确的触发
  var blocked: Bool
  /// 同步区不在：先建区
  var zoneMissing: Bool
}
