import Foundation
import Synchronization

/// 退避：指数加长、一半随机抖动；同步层的重试（发送者、认账号）都按它。
struct Backoff: Sendable {
  static let first = Duration.seconds(2)
  static let cap = Duration.seconds(300)
  /// 有话在等（马上传了还没收下）时的上限：断网久了恢复后，在等的话至多再晚这么久（连通的证据另会当场叫醒）。
  static let waitingCap = Duration.seconds(15)
  private var failures = 0

  /// 又失败了一次，下次隔多久。
  mutating func next(cap: Duration = Self.cap) -> Duration {
    failures += 1
    let base = min(Self.first * (1 << min(failures - 1, 16)), cap)
    // 一半固定、一半随机：同一阵子失败的设备不在同一刻一起重来
    return base / 2 + base / 2 * Double.random(in: 0...1)
  }

  mutating func reset() { failures = 0 }
}

/// 同步自己给请求定的时限（CloudKit 自己的空闲超时见 `CloudDatabase.requestTimeout`）。
enum RequestLimits {
  /// 不带数据的请求（认账号）至多等这么久，到点算连不上。
  static let request = Duration.seconds(15)
  /// 一次读（拉变化、按 ID 取）这么久没回音就同样的再发一次，先回来的算（`hedged`）：一拉挂住，后面的拉不跟着等。
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
    try await withCheckedThrowingContinuation { race.begin($0, legs) }
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
    var continuation: CheckedContinuation<T, any Error>?
    var tasks: [Task<Void, Never>] = []
    var running = 0
  }

  private let state = Mutex(State())

  func begin(_ continuation: CheckedContinuation<T, any Error>, _ legs: [Leg]) {
    guard !Task.isCancelled else { return continuation.resume(throwing: CancellationError()) }
    state.withLock { $0.continuation = continuation }
    let tasks = legs.map { leg in
      Task {
        if leg.delay > .zero { try? await Task.sleep(for: leg.delay) }
        guard !Task.isCancelled, self.enter() else { return }
        do { self.finish(.success(try await leg.run())) } catch { self.failed(error, decisive: leg.decisive) }
      }
    }
    let finished = state.withLock { state in
      if state.continuation != nil { state.tasks = tasks }
      return state.continuation == nil
    }
    if finished { tasks.forEach { $0.cancel() } }
  }

  private func enter() -> Bool {
    state.withLock { state in
      guard state.continuation != nil else { return false }
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

  func finish(_ result: Result<T, any Error>) {
    let (continuation, tasks) = state.withLock { state in
      defer { (state.continuation, state.tasks) = (nil, []) }
      return (state.continuation, state.tasks)
    }
    tasks.forEach { $0.cancel() }
    continuation?.resume(with: result)
  }
}
