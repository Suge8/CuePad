import CloudKit
import Foundation

/// 对外的同步状态，界面直接显示。本机数据在任何状态下都完好，可继续使用。
public enum SyncStatus: Equatable, Sendable {
  /// 正在连接 iCloud：引擎刚创建，还没确认账号状态。
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
  /// 这台设备没有在同步（原因给用户看）：没有同步引擎（隔离模式、构建没有 iCloud 权限）或引擎没能启动。由 App 层设置。
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

/// 界面订阅的同步快照：状态与最近的问题一起给出，任一变化都送达。
public struct SyncState: Equatable, Sendable {
  public var status: SyncStatus
  public var issues: [SyncIssue]

  public init(status: SyncStatus, issues: [SyncIssue]) {
    self.status = status
    self.issues = issues
  }
}

enum AccountChange: Sendable { case signedIn, signedOut, switched }

enum CloudDataLoss: Sendable { case deleted, purged, encryptedDataReset }

/// CKSyncEngine 的事件，收窄成同步逻辑真正用到的部分（真实引擎经 `EngineBridge` 翻译，测试直接构造）。
enum CloudEvent: Sendable {
  case stateUpdate(Data)
  case accountStatus(CKAccountStatus)
  case accountChange(AccountChange)
  case cloudDataLost(CloudDataLoss)
  case syncing(Bool)
  case fetched(modifications: [CKRecord], deletions: [(id: CKRecord.ID, recordType: String)])
  case sent(
    saved: [CKRecord], failedSaves: [(record: CKRecord, error: CKError)], deleted: [CKRecord.ID],
    failedDeletes: [(id: CKRecord.ID, error: CKError)])
  case zoneSaveFailed(CKError)
}

/// 同步逻辑向引擎登记待办的窄接口（真实实现写 `CKSyncEngine.state`）。
protocol ChangeQueue: Sendable {
  func enqueue(saves: [CKRecord.ID], deletes: [CKRecord.ID]) async
  func ensureZone(_ zoneID: CKRecordZone.ID) async
}
