import CloudKit
import CueStore
import Foundation
import Synchronization

/// 同步测量连的云（`sync-bench.py`，只经 `DebugHooks.cloudSync` 用；Release 里没人调）：默认是几个进程共用的模拟云（`SharedCloud`），
/// 确认时才连真的 iCloud 开发环境，这时请求数有上限（`budget`：用满就当断网，不再打 iCloud，脚本据此收场）。
/// 断网开关（`sync-bench.py offline`）：只让这个进程的请求失败，不碰机器的网络、别的进程与正式版。
/// 断着时每个请求当场像断网那样失败（底层 -1009，见 `Cut`），恢复后照常。网络路径监视器（`NetworkReturns`）不知道这次断开：
/// 恢复时 `set(false, pathReturns: true)` 替它报一次网络回来（真断网的恢复），`false` 是路径一直可用、只是 iCloud 连不上的那种恢复。
public enum CloudOutage {
  private static let down = Atomic<Bool>(false)
  private static let spent = Atomic<Int>(0)

  public static func set(_ isDown: Bool, pathReturns: Bool = false) {
    down.store(isDown, ordering: .relaxed)
    if !isDown, pathReturns { NetworkReturns.simulateReturn() }
  }

  /// 请求都经断网开关的同步（其余与 `CloudSync(store:)` 相同）。`shared`：模拟云的目录（`SharedCloud`；nil 连真的 iCloud）；
  /// `budget`：连真的 iCloud 时这个进程至多发这么多个请求。
  public static func cloudSync(store: CueStore, shared: URL?, budget: Int?) -> CloudSync {
    CloudSync(store: store) {
      if let shared { return Cut(base: SharedCloud(directory: shared), budget: nil) }
      return Cut(base: CloudDatabase(container: CKContainer(identifier: AppIdentity.iCloudContainer), zoneID: CloudSync.zoneID), budget: budget)
    }
  }

  /// 已经发出的请求数（连真的 iCloud 时对着 `budget` 数）。
  public static var requests: Int { spent.load(ordering: .relaxed) }

  /// 断着时每个请求都交给断了网的替身（`UnreachableCloud`：拉取、订阅是包着的 -1009，上传是逐条 -1009 的 `partialFailure`），
  /// 认账号也失败（替身认得出账号，真断网认不出）。
  /// 请求数用满（`budget`）也走这里：当断网。
  private struct Cut: SyncCloud {
    let base: any SyncCloud
    let budget: Int?

    private var now: any SyncCloud { cut ? UnreachableCloud() : base }

    private var cut: Bool {
      if down.load(ordering: .relaxed) { return true }
      let used = spent.wrappingAdd(1, ordering: .relaxed).newValue
      return budget.map { used > $0 } ?? false
    }

    private func reachable() throws {
      if cut { throw UnreachableCloud.failure }
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
