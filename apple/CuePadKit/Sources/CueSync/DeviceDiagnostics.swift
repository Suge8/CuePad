import CloudKit
import Foundation

public struct DeviceDiagnostic: Equatable, Sendable {
  public var device: String
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
  public func sendDiagnostics(saving: [DeviceDiagnostic], deleting: [DeviceDiagnostic.Key]) async throws {
    let cloud = try await usableCloud(for: .upload(urgent: false))
    let sent: SentRecords
    do {
      sent = try await cloud.uploadDiagnostics(saving: saving.map(DiagnosticZone.record), deleting: deleting.map(DiagnosticZone.id))
    } catch {
      throw await heldIfThrottled(error)
    }
    let unknown = Set(sent.failedDeletes.filter { $0.error.code == .unknownItem }.map(\.id))
    if let failure = sent.failedSaves.first?.error ?? sent.failedDeletes.first(where: { !unknown.contains($0.id) })?.error {
      throw await heldIfThrottled(failure)
    }
  }

  public func diagnosticsAccount() async throws -> String {
    _ = try await usableCloud(for: .upload(urgent: false))
    guard let account = try await coordinator.store.syncState(SyncCoordinator.accountKey) else { throw CancellationError() }
    return String(decoding: account, as: UTF8.self)
  }

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
