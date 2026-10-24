import Foundation
import Synchronization

/// 订阅的登记与提交序号（`CueStore.observe`）。提交在资料库队列上登记（本连接的写事务、别的进程按表来的通知），
/// 重读在另一条队列的只读连接上（`CueStore.rereader`），两边都要读写它，所以上锁；锁里只有字典与数组的操作。
///
/// 重读在另一个连接上，读与"把订阅收窄到这次读到的表"之间可能有提交进来：重读前记下序号，读完收窄时
/// 查其间的提交碰没碰这次读到的表，碰了再叫醒一次（`settle`）。为此留着最近的提交各碰了哪些表。
/// 按行收窄的（`narrow`）：行集在重读那一刻的读事务里取；提交时按行判断（`CueStore.touches`）在写连接上、提交之后当场查，
/// 看到的正是这次提交后的库。收窄登记晚于某次提交时，那次提交用的是旧的登记，由 `settle` 按表回看补叫醒（多读一次，不会漏）。
final class Subscriptions: Sendable {
  struct Subscriber: Sendable {
    var tables: Set<Table>
    var scopes: [Table: [RowScope]]
    let signal: AsyncStream<Void>.Continuation
  }

  private struct State {
    var subscribers: [UUID: Subscriber] = [:]
    /// 提交过几次（只算碰了可订阅的表的）；快照与重读据此知道其间有没有写入。
    var commits = 0
    var recent: [(commit: Int, tables: Set<Table>)] = []
  }

  /// 收窄时回看的提交数：一次重读期间进来的提交远少于此；更早的已不在其中时按碰过处理（多读一次）。
  private static let recentLimit = 64
  private let state = Mutex(State())

  var commits: Int { state.withLock(\.commits) }

  /// 登记订阅 `tables`；`since` 是读到手里那份时的提交数，其后有过提交（或没读过：nil）就先叫醒一次。
  func add(_ signal: AsyncStream<Void>.Continuation, reading tables: Set<Table>, scopes: [Table: [RowScope]], since: Int?) -> UUID {
    let token = UUID()
    let stale = state.withLock {
      $0.subscribers[token] = Subscriber(tables: tables, scopes: scopes, signal: signal)
      return since != $0.commits
    }
    if stale { signal.yield() }
    return token
  }

  func remove(_ token: UUID) { _ = state.withLock { $0.subscribers.removeValue(forKey: token) } }

  /// 一次提交碰了 `tables`：记下，返回读到其中某张表的订阅者（按行收窄的由调用方再判断，见 `CueStore.touches`）。
  func committed(_ tables: Set<Table>) -> [Subscriber] {
    state.withLock {
      $0.commits += 1
      $0.recent.append(($0.commits, tables))
      if $0.recent.count > Self.recentLimit { $0.recent.removeFirst() }
      return $0.subscribers.values.filter { !$0.tables.isDisjoint(with: tables) }
    }
  }

  /// 一次重读完：把订阅收窄到读到的表；从 `before`（重读前的提交数）起有提交碰过它们，再叫醒一次。
  func settle(_ token: UUID, reading tables: Set<Table>, scopes: [Table: [RowScope]], since before: Int) {
    let signal: AsyncStream<Void>.Continuation? = state.withLock {
      guard $0.subscribers[token] != nil else { return nil }
      $0.subscribers[token]?.tables = tables
      $0.subscribers[token]?.scopes = scopes
      guard $0.commits != before else { return nil }
      let later = $0.recent.drop { $0.commit <= before }
      let covered = later.first?.commit == before + 1
      return !covered || later.contains { !$0.tables.isDisjoint(with: tables) } ? $0.subscribers[token]?.signal : nil
    }
    signal?.yield()
  }
}
