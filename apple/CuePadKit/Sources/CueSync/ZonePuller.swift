import CloudKit
import CueStore
import Foundation

actor ZonePuller {
  static let tokenKey = "zoneToken"
  static let versionKeys = ["modifiedAt", PeerFloor.field]
  static let fieldsWithoutFiles = Array(Set(Table.synced.flatMap(\.columns)).subtracting(["id"]).union([PeerFloor.field])).sorted()

  private let source: any ZoneChangeSource
  private let coordinator: SyncCoordinator
  private let generation: SyncGeneration
  private var running: (id: UUID, task: Task<SyncPullResult, any Error>)?
  private var queued: (id: UUID, task: Task<SyncPullResult, any Error>)?
  private var owed = false

  init(source: any ZoneChangeSource, coordinator: SyncCoordinator, generation: SyncGeneration = SyncGeneration()) {
    self.source = source
    self.coordinator = coordinator
    self.generation = generation
  }

  func stop() async {
    generation.end()
    let tasks = [running?.task, queued?.task].compactMap { $0 }
    tasks.forEach { $0.cancel() }
    for task in tasks { _ = await task.result }
  }

  private var store: CueStore { coordinator.store }

  @discardableResult
  func pull() async throws -> SyncPullResult {
    guard !generation.isOver else { return .incomplete }
    if let queued { return try await wait(queued.task) }
    let id = UUID()
    let previous = running?.task
    let task = Task {
      _ = await previous?.result
      return try await self.run(id)
    }
    if previous == nil { running = (id, task) } else { queued = (id, task) }
    return try await wait(task)
  }

  private func wait(_ task: Task<SyncPullResult, any Error>) async throws -> SyncPullResult {
    do {
      return try await generation.outcome(of: task)
    } catch is CancellationError where generation.isOver {
      return .incomplete
    }
  }

  private func run(_ id: UUID) async throws -> SyncPullResult {
    if queued?.id == id {
      running = queued
      queued = nil
    }
    defer { if running?.id == id { running = nil } }
    guard !generation.isOver, await coordinator.canSync else { return .incomplete }
    let changed: Bool
    do {
      do {
        changed = try await drain()
      } catch let error as CKError where error.code == .changeTokenExpired {
        try live()
        try await coordinator.setToken(nil)
        changed = try await drain()
      }
    } catch where generation.isOver {
      throw CancellationError()
    } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {
      await coordinator.zoneMissing(deletedByUser: error.code == .userDeletedZone)
      return .incomplete
    } catch is RetryHeld {
      return .incomplete
    } catch {
      if !(error is SyncPaused) {
        let fault = await coordinator.failed(error)
        if fault.isWait || fault.retryAfter != nil {
          owed = true
          await coordinator.hold(fault, waiting: true)
        }
      }
      throw error
    }
    try live()
    await coordinator.succeeded()
    return changed ? .newData : .noData
  }

  func due() async {
    guard owed else { return }
    owed = false
    _ = try? await pull()
  }

  private func admitted() async throws {
    try live()
    owed = true
    guard await coordinator.admits(.pull) else { throw RetryHeld() }
    owed = false
  }

  private func live() throws {
    if generation.isOver { throw CancellationError() }
  }

  private func drain() async throws -> Bool {
    let changed: Bool
    do {
      changed = try await drainPages()
    } catch {
      await coordinator.setCatchingUp(false)
      throw error
    }
    await coordinator.setCatchingUp(false)
    return changed
  }

  private func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
    try await hedged(after: RequestLimits.hedge) { [source] in
      try await self.admitted()
      return try await source.changes(since: token, keys: keys)
    }
  }

  private func drainPages() async throws -> Bool {
    var token = try await coordinator.token()
    var changed = false
    if token == nil {
      await coordinator.setCatchingUp(true)
      let caught = try await catchUp()
      (token, changed) = (caught.token, caught.changed)
      try live()
      try await coordinator.setToken(token)
    }
    var batch: ZoneChangeBatch
    repeat {
      batch = try await changes(since: token, keys: Self.fieldsWithoutFiles)
      if batch.moreComing { await coordinator.setCatchingUp(true) }
      try live()
      try await coordinator.pulled(batch.modifications, batch.deletions)
      changed = changed || !batch.modifications.isEmpty || !batch.deletions.isEmpty
      try live()
      if batch.token != token { try await coordinator.setToken(batch.token) }
      token = batch.token
    } while batch.moreComing
    return changed
  }

  private func catchUp() async throws -> (token: Data, changed: Bool) {
    let before = try await store.syncedRecords()
    var seen: [CKRecord.ID: Int64] = [:]
    var batch: ZoneChangeBatch
    var token: Data?
    repeat {
      batch = try await changes(since: token, keys: Self.versionKeys)
      try live()
      try await coordinator.meet(batch.modifications)
      for record in batch.modifications where RecordMapper.table(named: record.recordType) != nil {
        seen[record.recordID] = (record["modifiedAt"] as? NSNumber)?.int64Value ?? .max
      }
      for deletion in batch.deletions { seen[deletion.id] = nil }
      token = batch.token
    } while batch.moreComing

    let wanted = try await newerOnServer(seen, synced: before)
    var changed = false
    for start in stride(from: 0, to: wanted.count, by: CloudKitLimits.recordsPerRequest) {
      let ids = Array(wanted[start..<min(start + CloudKitLimits.recordsPerRequest, wanted.count)])
      try await admitted()
      let records = try await source.records(ids)
      let found = Set(records.map(\.recordID))
      for id in ids where !found.contains(id) { seen[id] = nil }
      try live()
      try await coordinator.pulled(records, [])
      changed = changed || !records.isEmpty
    }

    let names = Set(seen.keys.map(\.recordName))
    let after = try await store.syncedRecords()
    let gone = before.filter { name, version in !names.contains(name) && after[name]?.pushed == version.pushed }
    if !gone.isEmpty {
      try live()
      try await coordinator.pulled([], gone.map { (CKRecord.ID(recordName: $0.key, zoneID: coordinator.zoneID), $0.value.table.rawValue) })
    }
    return (batch.token, changed || !gone.isEmpty)
  }

  private func newerOnServer(_ seen: [CKRecord.ID: Int64], synced: [String: (table: Table, pushed: Int64)]) async throws -> [CKRecord.ID] {
    var local: [String: Int64] = [:]
    for table in Table.synced { local.merge(try await store.modifiedAts(in: table)) { $1 } }
    return seen.compactMap { id, server in
      guard let mine = local[id.recordName] else { return synced[id.recordName] == nil ? id : nil }
      return server > mine ? id : nil
    }
  }
}
