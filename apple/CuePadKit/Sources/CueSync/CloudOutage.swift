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
  private static let timings = Mutex<[String: [Double]]>([:])

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
  /// 每种请求（upload、fetch、records、other、file-upload、file-download）在 App 里从发起到返回的每次用时（秒）。
  public static var requestTimings: [String: [Double]] { timings.withLock { $0 } }

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

    func accountStatus() async throws -> CKAccountStatus { try await timed("other") { try reachable(); return try await base.accountStatus() } }
    func accountName() async throws -> String { try await timed("other") { try reachable(); return try await base.accountName() } }
    func relaySecret() async throws -> Data { try await timed("other") { try await now.relaySecret() } }
    func changes(since token: Data?, keys: [String]) async throws -> ZoneChangeBatch {
      try await timed("fetch") { try await now.changes(since: token, keys: keys) }
    }
    func records(_ ids: [CKRecord.ID]) async throws -> [CKRecord] { try await timed("records") { try await now.records(ids) } }
    func upload(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> SentRecords {
      try await timed("upload") { try await now.upload(saving: saving, deleting: deleting) }
    }
    func uploadFile(_ record: CKRecord, progress: @escaping @Sendable (Double) -> Void) async throws -> SentRecords {
      try await timed("file-upload") { try await now.uploadFile(record, progress: progress) }
    }
    func resumedFileUploads() async throws -> [ResumedUpload] { try await timed("other") { try await now.resumedFileUploads() } }
    func downloadFile(_ id: CKRecord.ID, progress: @escaping @Sendable (Double) -> Void) async throws -> CKRecord? {
      try await timed("file-download") { try await now.downloadFile(id, progress: progress) }
    }
    func saveZone() async throws { try await timed("other") { try await now.saveZone() } }
    func subscriptions() async throws -> [CKSubscription.ID: CKSubscription] { try await timed("other") { try await now.subscriptions() } }
    func save(_ subscription: CKSubscription) async throws { try await timed("other") { try await now.save(subscription) } }
    func delete(_ id: CKSubscription.ID) async throws { try await timed("other") { try await now.delete(id) } }

    /// 记下这一请求在 App 里从发起到返回的用时（含 CloudKit 进程间的开销与排队）：模拟云的延迟模型按它标定。
    private func timed<T>(_ kind: String, _ body: () async throws -> T) async throws -> T {
      let began = ContinuousClock.now
      defer {
        let took = (ContinuousClock.now - began) / .seconds(1)
        timings.withLock { $0[kind, default: []].append(took) }
      }
      return try await body()
    }
  }
}
