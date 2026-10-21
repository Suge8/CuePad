import CloudKit
import CueStore
import Foundation

/// 拉：从同步区的令牌起拉变化，交给协调器应用（`SyncCoordinator.pulled`）。令牌只有一份，存在库里（`syncState` 的 `zoneToken`，经协调器读写），
/// 每页应用完才前移：应用失败（库或附件文件写不进去、停下来等你决定）、网络中断或退出，下次从上一页接着拉，不会跨过没应用的变化。
/// 单条记录本身不合法（字段非法、附件缺文件或哈希不符）只报告、不挡令牌：它不会自己变好，挡住就永远拉不动了。
///
/// 没有令牌（新装、令牌过期、换账号后）按版本对一遍账，不把整个同步区的正文与附件下载一遍：
/// 先只带 `modifiedAt` 翻完同步区，再按 ID 分批取本机没有或服务器较新的整条；翻完时本机推送过、服务器上却已没有的
/// （没出现、翻的途中被删、补取时已不在），按在别处删掉处理（翻的那段时间里本机又推送过的不算，它们的推送时间变了）。
/// 之后每次只从令牌增量拉。
///
/// 一次只跑一个拉取：在跑时再来的排在它后面（排着的只有一个，后来的都等它），不会用同一个令牌拉两遍、旧令牌也不会盖掉新的。
actor ZonePuller {
  static let tokenKey = "zoneToken"
  /// 对账那一遍带回的字段（门槛记录的版本在这一遍就看，`SyncCoordinator.meet`）。
  static let versionKeys = ["modifiedAt", PeerFloor.field]

  private let source: any ZoneChangeSource
  private let coordinator: SyncCoordinator
  private var running: (id: UUID, task: Task<Void, any Error>)?
  private var queued: (id: UUID, task: Task<Void, any Error>)?

  init(source: any ZoneChangeSource, coordinator: SyncCoordinator) {
    self.source = source
    self.coordinator = coordinator
  }

  private var store: CueStore { coordinator.store }

  /// 拉到没有更多为止；在跑的那次结束后才开始（见类型注释）。同步区不在（被删、被重置）交给协调器判断要不要请你决定。
  func pull() async throws {
    if let queued { return try await queued.task.value }
    let id = UUID()
    let previous = running?.task
    let task = Task {
      _ = await previous?.result
      try await self.run(id)
    }
    if previous == nil { running = (id, task) } else { queued = (id, task) }
    try await task.value
  }

  private func run(_ id: UUID) async throws {
    if queued?.id == id {
      running = queued
      queued = nil
    }
    defer { if running?.id == id { running = nil } }
    do {
      try await drain()
    } catch let error as CKError where error.code == .changeTokenExpired {
      try await coordinator.setToken(nil)
      try await drain()
    } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {
      await coordinator.zoneMissing(deletedByUser: error.code == .userDeletedZone)
    }
  }

  private func drain() async throws {
    guard await coordinator.canSync else { return }
    do {
      try await drainPages()
    } catch {
      await coordinator.setCatchingUp(false)
      await coordinator.reached(error)  // 网络类失败：连不上 iCloud
      throw error
    }
    await coordinator.setCatchingUp(false)
    await coordinator.reached(nil)
  }

  private func drainPages() async throws {
    // 对账与积压了不止一页（离线久了、别处一下写了很多）算在同步中；一页就拉完的（按节奏每两三秒一次）不算，状态不跟着闪
    var token = try await coordinator.token()
    if token == nil {
      await coordinator.setCatchingUp(true)
      token = try await catchUp()
      try await coordinator.setToken(token)
    }
    var batch: ZoneChangeBatch
    repeat {
      batch = try await source.changes(since: token, keys: nil)
      if batch.moreComing { await coordinator.setCatchingUp(true) }
      try await coordinator.pulled(batch.modifications, batch.deletions)
      if batch.token != token { try await coordinator.setToken(batch.token) }  // 库里的就是 `token`：没有变化的一拉不写库
      token = batch.token
    } while batch.moreComing
  }

  /// 按版本对账（见类型注释），返回翻完时的令牌；补取、删除都应用完才返回，调用方随即存下。
  private func catchUp() async throws -> Data {
    let before = try await store.syncedRecords()
    var seen: [CKRecord.ID: Int64] = [:]
    var batch: ZoneChangeBatch
    var token: Data?
    repeat {
      batch = try await source.changes(since: token, keys: Self.versionKeys)
      try await coordinator.meet(batch.modifications)
      for record in batch.modifications where RecordMapper.table(named: record.recordType) != nil {
        seen[record.recordID] = (record["modifiedAt"] as? NSNumber)?.int64Value ?? .max
      }
      for deletion in batch.deletions { seen[deletion.id] = nil }  // 前页出现、翻的途中被删
      token = batch.token
    } while batch.moreComing

    let wanted = try await newerOnServer(seen, synced: before)
    for start in stride(from: 0, to: wanted.count, by: CloudKitLimits.recordsPerRequest) {
      let ids = Array(wanted[start..<min(start + CloudKitLimits.recordsPerRequest, wanted.count)])
      let records = try await source.records(ids)
      let found = Set(records.map(\.recordID))
      for id in ids where !found.contains(id) { seen[id] = nil }  // 补取时已不在
      try await coordinator.pulled(records, [])
    }

    let names = Set(seen.keys.map(\.recordName))
    let after = try await store.syncedRecords()
    let gone = before.filter { name, version in !names.contains(name) && after[name]?.pushed == version.pushed }
    if !gone.isEmpty {
      try await coordinator.pulled([], gone.map { (CKRecord.ID(recordName: $0.key, zoneID: coordinator.zoneID), $0.value.table.rawValue) })
    }
    return batch.token
  }

  /// 本机没有（也没推送过）或服务器上较新的记录。
  private func newerOnServer(_ seen: [CKRecord.ID: Int64], synced: [String: (table: Table, pushed: Int64)]) async throws -> [CKRecord.ID] {
    var local: [String: Int64] = [:]
    for table in Table.synced { local.merge(try await store.modifiedAts(in: table)) { $1 } }
    return seen.compactMap { id, server in
      guard let mine = local[id.recordName] else { return synced[id.recordName] == nil ? id : nil }  // 推送过、本机已删的不取
      return server > mine ? id : nil
    }
  }
}
