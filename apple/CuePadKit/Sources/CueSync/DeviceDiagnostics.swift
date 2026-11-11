import CloudKit
import Foundation

/// 一台设备的一份诊断文件（MetricKit 的原始 JSON、本机记下的主线程卡住、最近日志），经你自己的 iCloud 私有库送到你的 Mac（App 的 `DiagnosticInbox` 落成文件）。
/// 单独一个区（`DiagnosticZone`），不进业务同步区：已发出的版本拉到会当未知类型报给你（同 `RelaySecret`）。一份文件一条记录；
/// 每台只写、只删自己的（发送方留几份由它定，删掉的同样删云上的），Mac 读全部。
public struct DeviceDiagnostic: Equatable, Sendable {
  public var device: String
  /// 给人看的设备名，Mac 落盘时按它分目录。
  public var deviceName: String
  public var file: String
  public var content: Data

  /// 一条记录连字段不超过 1MB；留出名字与加密的余量。大于它的发送方不传。
  public static let maxBytes = 900_000

  public init(device: String, deviceName: String, file: String, content: Data) {
    self.device = device
    self.deviceName = deviceName
    self.file = file
    self.content = content
  }

  public var key: Key { Key(device: device, file: file) }

  /// 记录名就是 "<设备>.<文件名>"：删除只交回记录 ID，Mac 靠它认出删的是哪台的哪一份。设备 ID（iOS 的 identifierForVendor、Mac 的 `mac-…`）里没有点。
  public struct Key: Hashable, Sendable {
    public var device: String
    public var file: String

    public init(device: String, file: String) {
      self.device = device
      self.file = file
    }

    var recordName: String { "\(device).\(file)" }

    init?(recordName: String) {
      guard let dot = recordName.firstIndex(of: "."), dot != recordName.startIndex else { return nil }
      device = String(recordName[..<dot])
      file = String(recordName[recordName.index(after: dot)...])
    }
  }
}

public struct DiagnosticChanges: Sendable {
  public var saved: [DeviceDiagnostic]
  public var deleted: [DeviceDiagnostic.Key]
  public var token: Data
  /// 从头读的（没给令牌，或令牌已失效、区不在）：`saved` 就是云上的全部，本地多出来的都该删。
  public var complete: Bool
}

enum DiagnosticZone {
  static let zoneID = CKRecordZone.ID(zoneName: "Diagnostics", ownerName: CKCurrentUserDefaultName)
  static let recordType = "deviceDiagnostics"
  static let nameField = "deviceName"
  static let contentField = "content"

  static func record(_ diagnostic: DeviceDiagnostic) -> CKRecord {
    let record = CKRecord(recordType: recordType, recordID: id(diagnostic.key))
    record.encryptedValues[nameField] = diagnostic.deviceName
    record.encryptedValues[contentField] = diagnostic.content
    return record
  }

  static func id(_ key: DeviceDiagnostic.Key) -> CKRecord.ID { CKRecord.ID(recordName: key.recordName, zoneID: zoneID) }

  static func diagnostic(_ record: CKRecord) throws -> DeviceDiagnostic {
    guard let key = DeviceDiagnostic.Key(recordName: record.recordID.recordName),
          let content = record.encryptedValues[contentField] as? Data
    else { throw CocoaError(.coderReadCorrupt) }
    let name = record.encryptedValues[nameField] as? String ?? key.device
    return DeviceDiagnostic(device: key.device, deviceName: name, file: key.file, content: content)
  }

  /// 拉到底，一次交回。只有几十份、每份至多 `DeviceDiagnostic.maxBytes`，不分页给调用方。
  static func changes(since token: Data?, in cloud: any SyncCloud) async throws -> DiagnosticChanges {
    var token = token
    var complete = token == nil
    var saved: [DeviceDiagnostic.Key: DeviceDiagnostic] = [:], deleted = Set<DeviceDiagnostic.Key>()
    while true {
      let batch: ZoneChangeBatch
      do {
        batch = try await cloud.diagnosticChanges(since: token)
      } catch let error as CKError where error.code == .changeTokenExpired && token != nil {
        (token, complete, saved, deleted) = (nil, true, [:], [])
        continue
      } catch let error as CKError where error.code == .zoneNotFound {
        // 还没有哪台送过（或换了账号）：云上什么都没有
        return DiagnosticChanges(saved: [], deleted: [], token: Data(), complete: true)
      }
      for record in batch.modifications where record.recordType == recordType {
        let diagnostic = try diagnostic(record)
        saved[diagnostic.key] = diagnostic
        deleted.remove(diagnostic.key)
      }
      for gone in batch.deletions {
        guard let key = DeviceDiagnostic.Key(recordName: gone.id.recordName) else { continue }
        saved[key] = nil
        deleted.insert(key)
      }
      token = batch.token
      guard batch.moreComing else { break }
    }
    return DiagnosticChanges(
      saved: saved.values.sorted { ($0.device, $0.file) < ($1.device, $1.file) }, deleted: complete ? [] : Array(deleted),
      token: token ?? Data(), complete: complete)
  }
}

extension CloudDatabase {
  private var diagnostics: CloudDatabase { CloudDatabase(container: container, zoneID: DiagnosticZone.zoneID) }

  func diagnosticChanges(since token: Data?) async throws -> ZoneChangeBatch {
    try await diagnostics.changes(since: token.flatMap { $0.isEmpty ? nil : $0 }, keys: [DiagnosticZone.nameField, DiagnosticZone.contentField])
  }

  /// 每台只写自己的记录、每次都是整份新建（不带服务器版本）：覆盖写。卡住记录恢复后原地改写、上一批部分传成后重传，都是改已有的记录。
  func uploadDiagnostics(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
    do {
      return try await diagnostics.upload(saving: saving, deleting: deleting, policy: .allKeys).throwingZoneMissing()
    } catch let error as CKError where error.code == .zoneNotFound {
      try await diagnostics.saveZone()
      return try await diagnostics.upload(saving: saving, deleting: deleting, policy: .allKeys)
    }
  }
}

extension SentRecords {
  /// 区不在时 CloudKit 逐条报 zoneNotFound：整批当区不在，建了区再传一次。
  fileprivate func throwingZoneMissing() throws -> SentRecords {
    let errors = failedSaves.map(\.error) + failedDeletes.map(\.error)
    if let missing = errors.first(where: { $0.code == .zoneNotFound }) { throw missing }
    return self
  }
}

extension CloudSync {
  /// 本机的诊断传上去、云上删掉本机已不留的。等账号认好再发（同 `relaySecret`）；同步被限流时不另发请求，抛 `RetryHeld`，
  /// 诊断自己被限流的同样让同步按服务器给的时刻等（同一台设备共用一份限流）。没传成的整批抛出，由调用方下次再对一遍。
  public func sendDiagnostics(saving: [DeviceDiagnostic], deleting: [DeviceDiagnostic.Key]) async throws {
    let cloud = try await usableCloud(for: .upload(urgent: false))
    let sent: SentRecords
    do {
      sent = try await cloud.uploadDiagnostics(saving: saving.map(DiagnosticZone.record), deleting: deleting.map(DiagnosticZone.id))
    } catch {
      throw await heldIfThrottled(error)
    }
    let unknown = Set(sent.failedDeletes.filter { $0.error.code == .unknownItem }.map(\.id))  // 云上本来就没有
    if let failure = sent.failedSaves.first?.error ?? sent.failedDeletes.first(where: { !unknown.contains($0.id) })?.error {
      throw await heldIfThrottled(failure)
    }
  }

  /// 等账号认好（同 `relaySecret`），返回资料所属的 iCloud 账号：发送方按它记传过哪些，换了账号就从头传。
  public func diagnosticsAccount() async throws -> String {
    _ = try await usableCloud(for: .upload(urgent: false))
    guard let account = try await coordinator.store.syncState(SyncCoordinator.accountKey) else { throw CancellationError() }
    return String(decoding: account, as: UTF8.self)
  }

  /// 各台送来的诊断自 `token` 以来的变化（nil 从头读）。
  public func diagnosticChanges(since token: Data?) async throws -> DiagnosticChanges {
    let cloud = try await usableCloud(for: .pull)
    do {
      return try await DiagnosticZone.changes(since: token, in: cloud)
    } catch {
      throw await heldIfThrottled(error)
    }
  }

  private func heldIfThrottled(_ error: any Error) async -> any Error {
    let fault = SyncFault(error)
    if fault.isWait { await coordinator.hold(fault, waiting: false) }
    return error
  }
}
