import Foundation
import Synchronization

/// 一半固定、一半随机：同一阵子失败的设备不在同一刻一起重来。
public struct Backoff: Sendable {
  /// 断了久了恢复后至多再晚这么久（连通的证据另会当场叫醒），每台设备约 15 秒试一次，代价可以忽略。
  public static let waitingCap = Duration.seconds(15)
  private let first: Duration
  private let cap: Duration
  private var failures = 0

  public init(first: Duration = .seconds(2), cap: Duration = .seconds(300)) {
    self.first = first
    self.cap = cap
  }

  public mutating func next(cap: Duration? = nil) -> Duration {
    failures += 1
    let base = min(first * (1 << min(failures - 1, 16)), cap ?? self.cap)
    return base / 2 + base / 2 * Double.random(in: 0...1)
  }

  public mutating func reset() { failures = 0 }

  var isFresh: Bool { failures == 0 }
}

enum RequestLimits {
  static let request = Duration.seconds(15)
  static let hedge = Duration.seconds(3)
}

/// 至多等 `limit`：到点抛 `URLError(.timedOut)`（归为连不上），请求取消、不等它真的结束。
func withDeadline<T: Sendable>(_ limit: Duration, _ request: @escaping @Sendable () async throws -> T) async throws -> T {
  try await race([
    Race.Leg(run: request),
    Race.Leg(delay: limit, decisive: true) { throw URLError(.timedOut) },
  ])
}

/// 同一个读请求：先发一次，`after` 还没回音就再发一次（同一个令牌、同一批 ID，结果一样），先成功的那次胜出，另一次取消、结果不用。
/// 第二次还没发出时第一次就失败了，直接抛出（那是真的失败，不是挂住）。
func hedged<T: Sendable>(after delay: Duration, _ request: @escaping @Sendable () async throws -> T) async throws -> T {
  try await race([Race.Leg(run: request), Race.Leg(delay: delay, run: request)])
}

/// 几路里先有结论的那路：成功即交出；失败只在它是决定性的、或此刻没有别的路在跑时交出。交出后其余取消，不等它们结束
/// （CloudKit 的请求未必马上响应取消，等它就又被挂住）。
private func race<T: Sendable>(_ legs: [Race<T>.Leg]) async throws -> T {
  let race = Race<T>()
  return try await withTaskCancellationHandler {
    race.begin(legs)
    return try await race.answer.value()
  } onCancel: {
    race.finish(.failure(CancellationError()))
  }
}

private final class Race<T: Sendable>: Sendable {
  struct Leg: Sendable {
    var delay: Duration = .zero
    var decisive = false
    var run: @Sendable () async throws -> T
  }

  private struct State {
    var over = false
    var tasks: [Task<Void, Never>] = []
    var running = 0
  }

  private let state = Mutex(State())
  let answer = Promise<T>()

  func begin(_ legs: [Leg]) {
    guard !state.withLock({ $0.over }) else { return }
    let tasks = legs.map { leg in
      Task {
        if leg.delay > .zero { try? await Task.sleep(for: leg.delay) }
        guard !Task.isCancelled, self.enter() else { return }
        do { self.finish(.success(try await leg.run())) } catch { self.failed(error, decisive: leg.decisive) }
      }
    }
    let finished = state.withLock { state in
      if !state.over { state.tasks = tasks }
      return state.over
    }
    if finished { tasks.forEach { $0.cancel() } }
  }

  private func enter() -> Bool {
    state.withLock { state in
      guard !state.over else { return false }
      state.running += 1
      return true
    }
  }

  private func failed(_ error: any Error, decisive: Bool) {
    let ends = state.withLock { state in
      state.running -= 1
      return decisive || state.running == 0
    }
    if ends { finish(.failure(error)) }
  }

  /// 交出结论：只有在锁里把"比完了"翻过来的那一次答复，后到的（被取消的那路抛出的错、调用方的取消）直接返回，不跟胜出的抢答。
  func finish(_ result: Result<T, any Error>) {
    let tasks = state.withLock { state -> [Task<Void, Never>]? in
      guard !state.over else { return nil }
      defer { (state.over, state.tasks) = (true, []) }
      return state.tasks
    }
    guard let tasks else { return }
    tasks.forEach { $0.cancel() }
    answer.resolve(result)
  }
}
