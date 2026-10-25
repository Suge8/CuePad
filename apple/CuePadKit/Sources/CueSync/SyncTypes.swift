import CloudKit
import CueStore

/// 对外的同步状态，界面直接显示。本机数据在任何状态下都完好，可继续使用。
public enum SyncStatus: Equatable, Sendable {
  /// 正在连接 iCloud：同步刚开始，还没确认账号状态。
  case starting
  /// 空闲（已同步，或尚无可同步的内容）。
  case idle
  /// 空闲之上的显示态：一轮上传或拉积压正在进行（`SyncState.catchingUp`）。只出现在快照里，由协调器在发布时推出，不单独记。
  case syncing
  /// 连不上 iCloud（没有网络、服务暂不可用）：最近一次拉取或上传因网络失败。本机改动留在库里待推送，发送者按退避重试；
  /// 下一次拉取或上传成功时回到空闲。
  case offline
  case noAccount
  /// iCloud 账号受限（家长控制或设备管理）。
  case accountRestricted
  /// 账号暂时不可用或无法确定，稍后会自动重试。
  case accountUnavailable
  /// iCloud 空间不足：本机改动保留并继续待推送，空间释放后自动恢复。
  case quotaExceeded
  /// 需要用户决定如何处理本机数据后才会继续同步，见 `SyncDecision`。
  case needsDecision(SyncDecision)
  /// 云端的最低对端版本（`PeerFloor`）高于这台的结构版本：停下同步，更新 CuePad 后继续；本机改动留在库里。
  case outdated
  /// 出现了未预期的失败，是哪些、为什么在 `issues`；会自动重试。
  case failed
  /// 这台设备没有在同步（原因给用户看）：隔离模式、构建没有 iCloud 权限。由 App 层设置。
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

/// 同步过程中遇到的、被跳过或没能处理的事项（未知记录类型、损坏的附件、单条记录写入失败等）。不静默。
/// 同一类、同一条记录只留一条（最新的原因）；上传与请求的问题在之后成功时自己消失（`Kind`）。
/// 给人看的说法由 `problem` 推出（App 的 `SyncIssue.text`），`detail` 是原话（错误码、服务端说明），只进可展开的详情。
public struct SyncIssue: Equatable, Sendable {
  public enum Kind: Sendable {
    /// 这条记录没能上传：它之后传上去了就消失。
    case upload
    /// 整个请求或本机读写出错：之后任何一次成功的往返就消失。
    case request
    /// 拉下来的记录被拒（未知类型、坏附件）：它不会自己变好，一直留着。
    case incoming
  }

  /// 出了什么事。连不上、要等、账号与配额不是问题，是状态（`SyncFault`）。
  public enum Problem: Equatable, Sendable {
    /// iCloud 没收下这条记录或这次请求（CloudKit 报的其余错误）
    case refused
    /// 本机读写出错（资料库、附件目录）
    case local
    /// 附件的文件不在本机，传不上去
    case fileMissing
    /// 拉到这版不认识的记录类型（更新版本的 CuePad 写的），已跳过
    case unknownType
    /// 拉到的附件没有文件或内容与哈希不符，已跳过
    case damaged

    /// 请求或读写失败的那一类：CloudKit 的错误是 iCloud 没收下，其余是本机。
    init(_ error: any Error) { self = error is CKError ? .refused : .local }
  }

  public var kind: Kind
  public var recordType: String?
  public var recordName: String?
  public var problem: Problem
  /// 原话：排查用，不当标题。
  public var detail: String?

  public init(kind: Kind = .incoming, recordType: String? = nil, recordName: String? = nil, problem: Problem, detail: String? = nil) {
    self.kind = kind
    self.recordType = recordType
    self.recordName = recordName
    self.problem = problem
    self.detail = detail
  }

  /// 去重的标识：同一类、同一条记录（整个请求的问题没有记录，同一类只留一条）。
  func sameAs(_ other: SyncIssue) -> Bool { kind == other.kind && recordName == other.recordName }

  /// 失败类的问题：有它们时状态是同步出错（`SyncStatus.failed`），都消失了回到空闲。
  var isFailure: Bool { kind != .incoming }
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
  /// 连不上 iCloud，还没建成（`SyncFault.offline`）；连上后的同步顺带重试。
  case offline
  /// 没能建立（完整原因，见 `Error.diagnosis`）；每次回到前台、账号变化时重试。
  case failed(String)
}

/// 界面订阅的同步快照：状态与最近的问题一起给出，任一变化都送达。
public struct SyncState: Equatable, Sendable {
  public var status: SyncStatus
  public var issues: [SyncIssue]
  public var alerts: PiAlertSubscriptionStatus
  /// 在一页页地拉积压（没有令牌时的对账，或一拉不止一页）：本机的数据还没跟上服务器。上传不算（`status` 的 `.syncing` 两者都算）。
  public var catchingUp: Bool
  /// 这台的库和 iCloud 完整对过至少一遍：库里有同步区令牌（拉完第一遍才存，换账号、云端数据被删或重置时清掉）。
  /// 没对过时，别的设备写下的事实（Cue 在哪台启用）可能还没到。
  public var reconciled: Bool

  public init(
    status: SyncStatus, issues: [SyncIssue], alerts: PiAlertSubscriptionStatus = .off, catchingUp: Bool = false, reconciled: Bool = false
  ) {
    self.status = status
    self.issues = issues
    self.alerts = alerts
    self.catchingUp = catchingUp
    self.reconciled = reconciled
  }
}

/// 服务器收下了本机的一批改动（`CloudSync.acceptedUpdates`，实时层据此按门铃）：收下的记录在哪些表、存下与删除各几条。
public struct AcceptedChanges: Equatable, Sendable {
  /// 存下的记录所在的表（删除只知道记录名，不在里面）。
  public var tables: Set<Table>
  public var saved: Int
  public var deleted: Int
}

/// 一批上传的结果交给发送者：有没有进展、同步区要不要建、该等什么（各条的失败合成一个，`SyncFault`）。
struct SendOutcome: Sendable {
  /// 有记录被收下，或被拒的已处理好（带上了服务器的版本标签等），接着发下一批不会原样再被拒
  var progressed: Bool
  var zoneMissing = false
  /// 有记录因可重试或要停下的原因被拒：这一轮到此为止，按它定下一次（nil：没有）。
  var fault: SyncFault?
}
