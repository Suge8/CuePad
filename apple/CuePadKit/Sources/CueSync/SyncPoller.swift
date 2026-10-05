import CueStore
import Foundation
import Synchronization

/// 有理由等就拉：同步引擎靠静默推送得知别的设备的改动，而这种推送不保证送达与时效，引擎自己也不会在没有推送时
/// 向服务器拉（见 `ZoneChangePuller`）。手里有正在等的东西时，按条件给出的节奏主动拉一次，推送仍是主通道。
///
/// 条件流给出此刻的节奏（nil：不在等）：在等时每 `interval` 拉一次，不再等即停；节奏带 `limit` 时，
/// 每次收到"在等"起最多拉这么久（收到新的"在等"重新计）。条件流结束或任务取消时返回。
public struct SyncPoller: Sendable {
  /// 多久拉一次，以及每次在等最多拉多久（nil：一直拉到不再等）。
  public struct Cadence: Equatable, Sendable {
    public var interval: Duration
    public var limit: Duration?

    public init(interval: Duration, limit: Duration? = nil) {
      self.interval = interval
      self.limit = limit
    }
  }

  public var timing: Timing

  public init(timing: Timing = .system) {
    self.timing = timing
  }

  /// 此刻的节奏、拉到什么时候为止（nil：不在等），以及有没有一个拉取循环在跑；条件消费与拉取循环共用。
  private final class State: Sendable {
    struct Value {
      var interval: Duration = .zero
      var until: Date?
      var looping = false
    }
    let value = Mutex(Value())
  }

  public func run<Condition: AsyncSequence & Sendable>(
    while waiting: Condition, fetch: @escaping @Sendable () async -> Void
  ) async where Condition.Element == Cadence?, Condition.Failure == Never {
    let state = State()
    await withTaskGroup(of: Void.self) { group in
      for await cadence in waiting {
        let now = timing.now()
        let start = state.value.withLock { s in
          s.until = cadence.map { $0.limit.map { now.addingTimeInterval(Self.seconds($0)) } ?? .distantFuture }
          guard let cadence else { return false }
          s.interval = cadence.interval
          guard !s.looping else { return false }
          s.looping = true
          return true
        }
        if start { group.addTask { await loop(state, fetch) } }
      }
      group.cancelAll()
    }
  }

  /// 按此刻的间隔醒来：还在等就拉，不再等（或过了上限）就结束；判断与标记结束在同一把锁里，不会漏开新循环。
  private func loop(_ state: State, _ fetch: @Sendable () async -> Void) async {
    while (try? await timing.sleep(state.value.withLock { $0.interval })) != nil {
      let now = timing.now()
      let keep = state.value.withLock { s in
        if let until = s.until, now <= until { return true }
        s.looping = false
        return false
      }
      guard keep else { return }
      await fetch()
    }
    state.value.withLock { $0.looping = false }
  }

  private static func seconds(_ duration: Duration) -> TimeInterval {
    TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18
  }
}
