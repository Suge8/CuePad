import CloudKit
import CueStore
import Foundation

/// 同步区里自某个令牌以来的一批变化。令牌是 `CKServerChangeToken` 的归档，测试可换成任意字节。
struct ZoneChangeBatch: Sendable {
  var modifications: [CKRecord]
  var deletions: [(id: CKRecord.ID, recordType: String)]
  var token: Data
  var moreComing: Bool
}

/// 能拉同步区变化的数据库（真实实现见 `DatabaseZoneChanges`）。`keys` 是要带回的字段（nil：整条记录）。
protocol ZoneChangeSource: Sendable {
  func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch
  /// 按 ID 取整条记录（取不到的略过）。一次不超过 `CloudKitLimits.recordsPerRequest` 条，由调用方分批。
  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord]
}

/// CloudKit 单次请求能带的记录数上限（超出报 `limitExceeded`）。
enum CloudKitLimits {
  static let recordsPerRequest = 400
}

/// 在等时的加速通道：不经 CKSyncEngine，直接向服务器拉同步区的变化，交给协调器与引擎同一个合并入口（`.fetched`）。
///
/// 为什么不用 `CKSyncEngine.fetchChanges`：引擎只拉它已知"有变化"的 zone，而这份名单只由推送、
/// 切到前台与"太久没拉"填上；没有推送时手动 fetchChanges（含限定 zone 的写法）不发任何请求。
///
/// 令牌只在内存、不持久化：持久的权威是引擎状态，这里只是"在等时"的加速，重启后重新取即可。
/// 第一次只带版本与状态（`versionKeys`）把令牌推进到"现在"，不把整个同步区的正文拉一遍；其间看到的"在等的表"
/// （`awaitedTables`）里要追的记录（`needsCatchUp`）按 ID 分批取整条交给协调器，不被令牌跨过；其余由引擎负责。
/// 令牌过期时清空重取。同一批变化之后还会经引擎到达，协调器的合并是幂等的。
actor ZoneChangePuller {
  /// 主动拉取等的是这些表（理由见 `AppServices.pollingCadence`）：投送请求（Mac 等着执行、手机等着结果）与
  /// Pi 会话状态（手机看着 Pi 页时要是活的）。Pi 会话状态含全部历史（几千条），所以取令牌时只补取要追的。
  /// 加新的等待理由时，它等的表要加进来。
  static let awaitedTables: Set<Table> = [.deliveryRequests, .piSessionStates]

  /// 取令牌那一遍带回的字段：版本（`modifiedAt`）与 Pi 会话的状态（明文），据此判断要不要补取，不带正文。
  static let versionKeys = ["modifiedAt", "state"]

  private let source: any ZoneChangeSource
  private let coordinator: SyncCoordinator
  private var token: Data?

  init(source: any ZoneChangeSource, coordinator: SyncCoordinator) {
    self.source = source
    self.coordinator = coordinator
  }

  /// 拉到没有更多为止。actor 串行：同时来的两次拉取依次进行，不会用同一个令牌拉两遍再互相覆盖。
  func pull() async throws {
    do {
      try await drain()
    } catch let error as CKError where error.code == .changeTokenExpired {
      token = nil
      try await drain()
    }
  }

  /// 还没有令牌就先取（补取在等的表里要追的）。手机发连接测试前调用：第一次的取令牌不算进往返。
  func prepare() async throws {
    do {
      try await takeTokenIfNeeded()
    } catch let error as CKError where error.code == .changeTokenExpired {
      token = nil
      try await takeTokenIfNeeded()
    }
  }

  /// 令牌只在补取完成后才记下：补取失败时下次重来，令牌不会先跨过还没取到的记录。
  private func takeTokenIfNeeded() async throws {
    guard token == nil else { return }
    var batch: ZoneChangeBatch
    var next: Data?
    var seen: [CKRecord] = []
    repeat {
      batch = try await source.changes(since: next, keys: Self.versionKeys)
      seen += batch.modifications.filter { Table(rawValue: $0.recordType).map(Self.awaitedTables.contains) == true }
      next = batch.token
    } while batch.moreComing
    try await catchUp(seen)
    token = next
  }

  /// 本机还没有的、或服务器上较新的，才补取；本机没有的 Pi 会话已结束就不追（历史由引擎带来）。
  private func catchUp(_ seen: [CKRecord]) async throws {
    var local: [Table: [String: Int64]] = [:]
    for table in Self.awaitedTables { local[table] = try await coordinator.store.modifiedAts(in: table) }
    let wanted = seen.filter { record in
      guard let table = Table(rawValue: record.recordType) else { return false }
      return Self.needsCatchUp(record, table: table, localModifiedAt: local[table]?[record.recordID.recordName])
    }.map(\.recordID)
    for start in stride(from: 0, to: wanted.count, by: CloudKitLimits.recordsPerRequest) {
      let ids = Array(wanted[start..<min(start + CloudKitLimits.recordsPerRequest, wanted.count)])
      await coordinator.handle(.fetched(modifications: try await source.records(ids), deletions: []))
    }
  }

  private static func needsCatchUp(_ record: CKRecord, table: Table, localModifiedAt: Int64?) -> Bool {
    let serverModifiedAt = (record["modifiedAt"] as? NSNumber)?.int64Value
    guard let localModifiedAt else {
      return !(table == .piSessionStates && record["state"] as? String == PiWorkState.ended.rawValue)
    }
    return serverModifiedAt.map { $0 > localModifiedAt } ?? true
  }

  private func drain() async throws {
    try await takeTokenIfNeeded()
    var batch: ZoneChangeBatch
    repeat {
      batch = try await source.changes(since: token, keys: nil)
      if !batch.modifications.isEmpty || !batch.deletions.isEmpty {
        await coordinator.handle(.fetched(modifications: batch.modifications, deletions: batch.deletions))
      }
      token = batch.token
    } while batch.moreComing
  }
}

/// 私有数据库里一个同步区的变化（`CKFetchRecordZoneChangesOperation`）。
struct DatabaseZoneChanges: ZoneChangeSource {
  let database: CKDatabase
  let zoneID: CKRecordZone.ID

  func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch {
    let since = try token.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
    let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: since, desiredKeys: keys)
    return ZoneChangeBatch(
      // 单条记录取失败的跳过：这条路只是加速，同一条记录会经引擎到达，失败由那条路报告
      modifications: result.modificationResultsByID.values.compactMap { try? $0.get().record },
      deletions: result.deletions.map { ($0.recordID, $0.recordType) },
      token: try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true),
      moreComing: result.moreComing)
  }

  func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] {
    // 取不到的（这期间被删了）略过
    try await database.records(for: ids).values.compactMap { try? $0.get() }
  }
}
