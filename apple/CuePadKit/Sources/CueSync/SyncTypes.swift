import CloudKit
import CueStore

/// 一次拉取的结果，不是全局同步状态：上传成功或重写本地快照都不能证明这次拉完了。
public enum SyncPullResult: Equatable, Sendable {
  case newData
  case noData
  case incomplete
}

/// 本机数据在任何状态下都完好，可继续使用。
public enum SyncStatus: Equatable, Sendable {
  case starting
  case idle
  /// 只出现在快照里，由协调器在发布时推出，不单独记。
  case syncing
  case offline
  case noAccount
  case accountRestricted
  case accountUnavailable
  case quotaExceeded
  case needsDecision(SyncDecision)
  case outdated
  case failed
  /// 由 App 层设置，同步层不产生；原因给用户看。
  case unavailable(String)
}

public enum SyncDecision: Equatable, Sendable {
  case accountSwitched
  /// 云端数据被删除（用户在 iCloud 设置里清除了 CuePad 数据）。
  case cloudDataDeleted
  /// 云端数据被重置（清除或加密数据重置），云端已没有之前的记录。
  case cloudDataReset
}

public enum SyncResolution: Sendable {
  case uploadLocal
  /// 丢弃本机的同步数据（卡片、项目、任务、附件等），从当前账号的云端重新开始。
  case eraseLocal
}

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

  /// 连不上、要等、账号与配额不是问题，是状态（`SyncFault`）。
  public enum Problem: Equatable, Sendable {
    case refused
    case local
    case fileMissing
    case unknownType
    case damaged

    init(_ error: any Error) { self = error is CKError ? .refused : .local }
  }

  public var kind: Kind
  public var recordType: String?
  public var recordName: String?
  public var problem: Problem
  public var detail: String?

  public init(kind: Kind = .incoming, recordType: String? = nil, recordName: String? = nil, problem: Problem, detail: String? = nil) {
    self.kind = kind
    self.recordType = recordType
    self.recordName = recordName
    self.problem = problem
    self.detail = detail
  }

  func sameAs(_ other: SyncIssue) -> Bool { kind == other.kind && recordName == other.recordName }

  var isFailure: Bool { kind != .incoming }
}

extension Error {
  /// CloudKit 的 `localizedDescription` 常只剩"错误 14"，原话在 userInfo 的说明项里；一批里逐条的失败取第一条，底层错误接在后面。
  /// 整个 `description` 带记录内容，不进日志；也不带请求编号之类的排查噪音。
  public var brief: String {
    let error = self as NSError
    let source: String? =
      switch error.domain {
      case CKErrorDomain: "CloudKit"
      case NSURLErrorDomain: "网络"
      default: nil
      }
    guard let source else { return self is LocalizedError || Swift.type(of: self) is NSError.Type ? localizedDescription : "\(self)" }
    if let items = error.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: any Error], let first = items.values.first {
      return "\(source) \(error.code)：\(items.count) 条失败，如 \(first.brief)"
    }
    let said = ["CKErrorDescription", "ServerErrorDescription", NSLocalizedDescriptionKey].lazy.compactMap { error.userInfo[$0] as? String }.first
    let under = (error.userInfo[NSUnderlyingErrorKey] as? any Error).map { "（\($0.brief)）" } ?? ""
    let name = error.domain == CKErrorDomain ? CKError.Code(rawValue: error.code)?.name.map { " \($0)" } ?? "" : ""
    return "\(source) \(error.code)\(name)" + (said.map { "：\($0)" } ?? "") + under
  }

  var diagnosis: String { "\(localizedDescription)（\(self)）" }
}

public enum AlertSubscriptionStatus: Equatable, Sendable {
  case off
  case active
  case offline
  case failed(String)
}

public struct SyncState: Equatable, Sendable {
  public var status: SyncStatus
  public var issues: [SyncIssue]
  public var alerts: AlertSubscriptionStatus
  /// 在拉积压：本机的数据还没跟上服务器。上传不算（`status` 的 `.syncing` 两者都算）。
  public var catchingUp: Bool
  /// 这台的库和 iCloud 完整对过至少一遍：库里有同步区令牌（拉完第一遍才存，换账号、云端数据被删或重置时清掉）。
  /// 没对过时，别的设备写下的事实（Cue 在哪台启用）可能还没到。
  public var reconciled: Bool
  /// 别的记录照常同步，`status` 不因它变。
  public var filesOverQuota: Bool

  public init(
    status: SyncStatus, issues: [SyncIssue], alerts: AlertSubscriptionStatus = .off, catchingUp: Bool = false, reconciled: Bool = false,
    filesOverQuota: Bool = false
  ) {
    self.status = status
    self.issues = issues
    self.alerts = alerts
    self.catchingUp = catchingUp
    self.reconciled = reconciled
    self.filesOverQuota = filesOverQuota
  }
}

struct SendOutcome: Sendable {
  /// 有记录被收下，或被拒的已处理好（带上了服务器的版本标签等），接着发下一批不会原样再被拒
  var progressed: Bool
  var zoneMissing = false
  /// 这一轮到此为止，按它定下一次。
  var fault: SyncFault?
  /// 协调器停下了（等你决定、要更新）：结果没记账，这一轮到此为止，不定重试时刻（停下不是失败；处理完重新开始时照常重传）。
  var paused = false
}

extension CKError.Code {
  fileprivate var name: String? {
    switch self {
    case .networkFailure: "networkFailure"
    case .networkUnavailable: "networkUnavailable"
    case .serviceUnavailable: "serviceUnavailable"
    case .serverResponseLost: "serverResponseLost"
    case .requestRateLimited: "requestRateLimited"
    case .zoneBusy: "zoneBusy"
    case .operationCancelled: "operationCancelled"
    case .batchRequestFailed: "batchRequestFailed"
    case .partialFailure: "partialFailure"
    case .notAuthenticated: "notAuthenticated"
    case .managedAccountRestricted: "managedAccountRestricted"
    case .accountTemporarilyUnavailable: "accountTemporarilyUnavailable"
    case .quotaExceeded: "quotaExceeded"
    case .serverRecordChanged: "serverRecordChanged"
    case .zoneNotFound: "zoneNotFound"
    case .userDeletedZone: "userDeletedZone"
    case .changeTokenExpired: "changeTokenExpired"
    case .limitExceeded: "limitExceeded"
    case .unknownItem: "unknownItem"
    case .serverRejectedRequest: "serverRejectedRequest"
    case .internalError: "internalError"
    default: nil
    }
  }
}
