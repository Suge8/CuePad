import Foundation
import Synchronization

final class Subscriptions: Sendable {
  struct Subscriber: Sendable {
    var tables: Set<Table>
    var scopes: [Table: [RowScope]]
    let signal: AsyncStream<Void>.Continuation
  }

  private struct State {
    var subscribers: [UUID: Subscriber] = [:]
    var commits = 0
    var recent: [(commit: Int, tables: Set<Table>)] = []
  }

  private static let recentLimit = 64
  private let state = Mutex(State())

  var commits: Int { state.withLock(\.commits) }

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


  func committed(_ tables: Set<Table>) -> [Subscriber] {
    state.withLock {
      $0.commits += 1
      $0.recent.append(($0.commits, tables))
      if $0.recent.count > Self.recentLimit { $0.recent.removeFirst() }
      return $0.subscribers.values.filter { !$0.tables.isDisjoint(with: tables) }
    }
  }

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
