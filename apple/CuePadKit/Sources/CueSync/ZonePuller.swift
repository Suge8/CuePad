import CloudKit
import CueStore
import Foundation

/// 令牌每页应用完才前移：应用失败（库写不进去、停下来等你决定）、网络中断或退出，下次从上一页接着拉，不会跨过没应用的变化。
/// 单条记录本身不合法（字段非法）只报告、不挡令牌：它不会自己变好，挡住就永远拉不动了。
///
/// 没有令牌（新装、令牌过期、换账号后）按版本对一遍账，不把整个同步区的正文下载一遍。翻完时本机推送过、服务器上却已没有的（没出现、翻的途中被删、补取时已不在）按在别处删掉处理；翻的那段时间里本机又推送过的不算，它们的推送时间变了。
///
/// 一次只跑一个拉取：在跑时再来的排在它后面（排着的只有一个，后来的都等它），不会用同一个令牌拉两遍、旧令牌也不会盖掉新的。
/// 拉变化的请求 `RequestLimits.hedge` 没回音就同样的再发一次、先回来的算（`hedged`）：一拉挂住，排在后面的拉不跟着等。
/// 拉取不带附件的文件（`fieldsWithoutFiles`），文件另走一路下载（`FileFetcher`），大文件不挡同一页的别的记录；对账时按 ID 补取的整条记录同样不带文件、不赛跑。
/// 等待期间来的拉取与因此失败的那一拉都记成欠一拉，等待结束时（`due`）补上，不靠下一次触发。
/// `stop` 之后本代不再写令牌、不再应用页；调用方被取消或这一代结束就不再等。
actor ZonePuller {
  static let tokenKey = "zoneToken"
  /// 对账那一遍带回的字段（门槛记录的版本在这一遍就看，`SyncCoordinator.meet`）。
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

  /// 请求挂住也不等：`hedged` 被取消当场返回。
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

  /// 等合并的那一拉：调用方被取消就抛出、不取消那一拉（别人也在等）；这一代结束了算没拉完。
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
      throw CancellationError()  // 停下了：失败不归类、不定重试
    } catch let error as CKError where [.zoneNotFound, .userDeletedZone].contains(error.code) {
      await coordinator.zoneMissing(deletedByUser: error.code == .userDeletedZone)
      return .incomplete
    } catch is RetryHeld {
      return .incomplete  // 欠一拉已在 `admitted` 里记下
    } catch {
      if !(error is SyncPaused) {
        let fault = await coordinator.failed(error)
        // 连不上又没给时刻的不记：拉取不守连不上的退避（`SyncCoordinator.Request.pull`），也不拿拉取的失败拖住上传
        if fault.isWait || fault.retryAfter != nil {
          owed = true  // 先记后定时刻：同 `admitted`
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
    _ = try? await pull()  // 失败已由协调器归类、定了下次的时刻
  }

  /// 发请求前问重试调度：在等就抛出，这一拉欠着。欠账先记后问：问的途中等待结束（`due` 先到）也不漏；放行了就是这一拉还上了。
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
    // 对账与积压了不止一页（离线久了、别处一下写了很多）算在同步中；一页就拉完的（按节奏的、门铃叫来的）不算，状态不跟着闪
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
      if batch.token != token { try await coordinator.setToken(batch.token) }  // 库里的就是 `token`：没有变化的一拉不写库
      token = batch.token
    } while batch.moreComing
    return changed
  }

  /// 补取、删除都应用完才返回。
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
      for deletion in batch.deletions { seen[deletion.id] = nil }  // 前页出现、翻的途中被删
      token = batch.token
    } while batch.moreComing

    let wanted = try await newerOnServer(seen, synced: before)
    var changed = false
    for start in stride(from: 0, to: wanted.count, by: CloudKitLimits.recordsPerRequest) {
      let ids = Array(wanted[start..<min(start + CloudKitLimits.recordsPerRequest, wanted.count)])
      try await admitted()
      let records = try await source.records(ids)
      let found = Set(records.map(\.recordID))
      for id in ids where !found.contains(id) { seen[id] = nil }  // 补取时已不在
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
      guard let mine = local[id.recordName] else { return synced[id.recordName] == nil ? id : nil }  // 推送过、本机已删的不取
      return server > mine ? id : nil
    }
  }
}
