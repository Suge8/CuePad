import CueStore
import Foundation

/// 有理由等就拉：同步引擎靠静默推送得知别的设备的改动，而这种推送不保证送达与时效，引擎自己也不会在没有推送时
/// 向服务器拉（见 `ZoneChangePuller`）。手里有正在等的东西时，按条件给出的节奏主动拉一次，推送仍是主通道。
///
/// 条件流给出此刻的节奏（nil：不在等）：每收到一个节奏就从头开始——立即拉一次（令牌与最新状态不等第一个间隔），之后按它的档位隔着拉；
/// 收到 nil 即停，条件流结束或任务取消时返回。
public struct SyncPoller: Sendable {
  /// 怎么拉：几档，每档隔多久拉一次、持续多久（`lasting` 为 nil 是一直），按顺序走；最后一档有期限的，走完就不再拉。
  /// 例：`Cadence(.every(.seconds(2), for: .seconds(120)), .every(.seconds(10)))` 是先 2 秒一次拉两分钟，之后 10 秒一次一直拉。
  public struct Cadence: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
      public var interval: Duration
      public var lasting: Duration?

      public static func every(_ interval: Duration, for lasting: Duration? = nil) -> Step {
        Step(interval: interval, lasting: lasting)
      }
    }

    public var steps: [Step]

    public init(_ steps: Step...) {
      self.steps = steps
    }

    /// 在等了 `elapsed` 之后该隔多久拉一次；nil：档位走完了，不再拉。
    func interval(after elapsed: Duration) -> Duration? {
      var rest = elapsed
      for step in steps {
        guard let lasting = step.lasting else { return step.interval }
        if rest < lasting { return step.interval }
        rest -= lasting
      }
      return nil
    }
  }

  public var timing: Timing

  public init(timing: Timing = .system) {
    self.timing = timing
  }

  public func run<Condition: AsyncSequence & Sendable>(
    while waiting: Condition, fetch: @escaping @Sendable () async -> Void
  ) async where Condition.Element == Cadence?, Condition.Failure == Never {
    var loop: Task<Void, Never>?
    for await cadence in waiting {
      loop?.cancel()
      loop = cadence.map { cadence in Task { await self.loop(cadence, fetch) } }
    }
    loop?.cancel()
    await loop?.value
  }

  /// 先拉一次，再按走到哪一档隔着拉，直到档位走完或被取消（新节奏到来、不再等）。
  private func loop(_ cadence: Cadence, _ fetch: @escaping @Sendable () async -> Void) async {
    let start = timing.now()
    while !Task.isCancelled, let interval = cadence.interval(after: .seconds(timing.now().timeIntervalSince(start))) {
      await Task { await fetch() }.value  // 新节奏到来只打断睡眠，不打断拉了一半的请求（取消会让它报错）。取消屏蔽 withTaskCancellationShield 要 macOS 27，部署目标是 26
      try? await timing.sleep(interval)
    }
  }
}
