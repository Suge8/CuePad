import CloudKit
import CueStore
import Foundation
import Synchronization

/// 同步测量的断网（`sync-bench.py offline`，只经 `DebugHooks.cloudSync` 用；Release 里没人调）：只让这个进程连 iCloud 的请求失败，不碰机器的网络、别的进程与正式版。
/// 断着时每个请求当场像断网那样失败（底层 -1009，见 `Cut`），恢复后照常。网络路径监视器（`NetworkReturns`）不知道这次断开：
/// 恢复时 `set(false, pathReturns: true)` 替它报一次网络回来（真断网的恢复），`false` 是路径一直可用、只是 iCloud 连不上的那种恢复。
public enum CloudOutage {
  private static let down = Atomic<Bool>(false)

  public static func set(_ isDown: Bool, pathReturns: Bool = false) {
    down.store(isDown, ordering: .relaxed)
    if !isDown, pathReturns { NetworkReturns.simulateReturn() }
  }

  /// 连 iCloud、请求都经断网开关的同步（其余与 `CloudSync(store:)` 相同）。
  public static func cloudSync(store: CueStore) -> CloudSync {
    CloudSync(store: store) {
      Cut(base: CloudDatabase(container: CKContainer(identifier: AppIdentity.iCloudContainer), zoneID: CloudSync.zoneID))
    }
  }

  /// 断着时每个请求都交给断了网的替身（`UnreachableCloud`：拉取、订阅是包着的 -1009，上传是逐条 -1009 的 `partialFailure`），
  /// 认账号也失败（替身认得出账号，真断网认不出）。
  private struct Cut: SyncCloud {
    let base: CloudDatabase
    private var now: any SyncCloud { down.load(ordering: .relaxed) ? UnreachableCloud() : base }

    private func reachable() throws {
      if down.load(ordering: .relaxed) { throw UnreachableCloud.failure }
    }

    func accountStatus() async throws -> CKAccountStatus { try reachable(); return try await base.accountStatus() }
    func accountName() async throws -> String { try reachable(); return try await base.accountName() }
    func relaySecret() async throws -> Data { try await now.relaySecret() }
    func changes(since token: Data?, keys: [String]?) async throws -> ZoneChangeBatch { try await now.changes(since: token, keys: keys) }
    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { try await now.records(ids) }
    func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords { try await now.upload(saving: saving, deleting: deleting) }
    func saveZone() async throws { try await now.saveZone() }
    func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { try await now.subscriptions() }
    func save(_ subscription: CKSubscription) async throws { try await now.save(subscription) }
    func delete(_ id: CKSubscription.ID) async throws { try await now.delete(id) }
  }
}
