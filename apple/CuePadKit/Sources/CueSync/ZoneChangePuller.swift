import CloudKit
import Foundation

/// 同步区里自某个令牌以来的一批变化。令牌是 `CKServerChangeToken` 的归档，测试可换成任意字节。
struct ZoneChangeBatch: Sendable {
  var modifications: [CKRecord]
  var deletions: [(id: CKRecord.ID, recordType: String)]
  var token: Data
  var moreComing: Bool
}

/// 能拉同步区变化的数据库（真实实现见 `DatabaseZoneChanges`）。`idsOnly` 时只要记录 ID、不要字段。
protocol ZoneChangeSource: Sendable {
  func changes(since token: Data?, idsOnly: Bool) async throws -> ZoneChangeBatch
}

/// 在等时的加速通道：不经 CKSyncEngine，直接向服务器拉同步区的变化，交给协调器与引擎同一个合并入口（`.fetched`）。
///
/// 为什么不用 `CKSyncEngine.fetchChanges`：引擎只拉它已知"有变化"的 zone，而这份名单只由推送、
/// 切到前台与"太久没拉"填上；没有推送时手动 fetchChanges（含限定 zone 的写法）不发任何请求。
///
/// 令牌只在内存、不持久化：持久的权威是引擎状态，这里只是"在等时"的加速，重启后重新取即可。
/// 第一次先只要 ID 把令牌推进到"现在"（不把整个同步区的字段拉一遍；在此之前的变化由引擎负责）；
/// 令牌过期时清空重取。同一批变化之后还会经引擎到达，协调器的合并是幂等的。
actor ZoneChangePuller {
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

  private func drain() async throws {
    if token == nil {
      var batch: ZoneChangeBatch
      repeat {
        batch = try await source.changes(since: token, idsOnly: true)
        token = batch.token
      } while batch.moreComing
    }
    var batch: ZoneChangeBatch
    repeat {
      batch = try await source.changes(since: token, idsOnly: false)
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

  func changes(since token: Data?, idsOnly: Bool) async throws -> ZoneChangeBatch {
    let since = try token.flatMap { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
    let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: since, desiredKeys: idsOnly ? [] : nil)
    return ZoneChangeBatch(
      // 单条记录取失败的跳过：这条路只是加速，同一条记录会经引擎到达，失败由那条路报告
      modifications: result.modificationResultsByID.values.compactMap { try? $0.get().record },
      deletions: result.deletions.map { ($0.recordID, $0.recordType) },
      token: try NSKeyedArchiver.archivedData(withRootObject: result.changeToken, requiringSecureCoding: true),
      moreComing: result.moreComing)
  }
}
