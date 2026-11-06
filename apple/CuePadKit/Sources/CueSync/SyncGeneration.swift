import Synchronization

/// 同步的一代：`CloudSync` 的一次 `start` 到 `stop`。本代的拉取器、发送者与文件两路共用一个，`stop` 一开始就结束它（`end`）：
/// 结束之后本代的任务不再改协调器与库（每个 await 之后看 `isOver`），本代里在等的（`outcome`）当场返回。
/// 代次只有这一种写法：组件不另记"停下了"，`CloudSync` 也不另记代次号。单独建的组件（测试）各自一代。
final class SyncGeneration: Sendable {
  private struct State {
    var over = false
    var waiters: [UInt64: @Sendable () -> Void] = [:]
    var next: UInt64 = 0
  }

  private let state = Mutex(State())

  var isOver: Bool { state.withLock { $0.over } }

  func end() {
    let waiters = state.withLock { state in
      state.over = true
      defer { state.waiters = [:] }
      return Array(state.waiters.values)
    }
    waiters.forEach { $0() }
  }

  /// 等 `task` 的结果：这一代先结束、或调用方被取消，就当场抛出 `CancellationError`，不等它结束（`task` 照样跑完，结果不用，也不取消它）。
  /// 可取消的等待只有这一种写法：合并的拉取、在等重试时刻的取文件、交给系统的长期上传都经它。
  func outcome<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
    let once = Once<T>()
    let id = state.withLock { state -> UInt64? in
      guard !state.over else { return nil }
      state.next += 1
      state.waiters[state.next] = { once.resume(with: .failure(CancellationError())) }
      return state.next
    }
    guard let id else { throw CancellationError() }
    defer { state.withLock { _ = $0.waiters.removeValue(forKey: id) } }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        once.set(continuation)
        Task { once.resume(with: await task.result) }
      }
    } onCancel: {
      once.resume(with: .failure(CancellationError()))
    }
  }
}

/// 一个续体只答一次：结果、取消与这一代结束谁先到算谁；先到的若早于续体登记，登记时当场答。
private final class Once<T: Sendable>: Sendable {
  private enum State {
    case idle
    case waiting(CheckedContinuation<T, any Error>)
    case early(Result<T, any Error>)
    case done
  }

  private let state = Mutex(State.idle)

  func set(_ continuation: CheckedContinuation<T, any Error>) {
    let early = state.withLock { state -> Result<T, any Error>? in
      guard case .early(let result) = state else {
        state = .waiting(continuation)
        return nil
      }
      state = .done
      return result
    }
    if let early { continuation.resume(with: early) }
  }

  func resume(with result: Result<T, any Error>) {
    let continuation = state.withLock { state -> CheckedContinuation<T, any Error>? in
      switch state {
      case .idle:
        state = .early(result)
        return nil
      case .waiting(let continuation):
        state = .done
        return continuation
      case .early, .done:
        return nil
      }
    }
    continuation?.resume(with: result)
  }
}
