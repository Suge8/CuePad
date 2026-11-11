import Synchronization

/// `CloudSync` 的一次 `start` 到 `stop`，本代各组件共用一个，`stop` 一开始就结束它（`end`）：
/// 结束之后本代的任务不再改协调器与库（每个 await 之后看 `isOver`），本代里在等的（`value(of:)`、`outcome(of:)`）当场抛出 `CancellationError`。
/// 代次只有这一种写法：组件不另记"停下了"，`CloudSync` 也不另记代次号。单独建的组件（测试）各自一代。
final class SyncGeneration: Sendable {
  private struct State {
    var over = false
    var waiting: [ObjectIdentifier: @Sendable () -> Void] = [:]
  }

  private let state = Mutex(State())

  var isOver: Bool { state.withLock { $0.over } }

  func end() {
    let waiting = state.withLock { state in
      state.over = true
      defer { state.waiting = [:] }
      return Array(state.waiting.values)
    }
    waiting.forEach { $0() }
  }

  /// 等 `promise` 的答复；这一代先结束就当场抛出 `CancellationError`（已结束的不等）。调用方被取消照 `cancellable`（见 `Promise.value`）。
  func value<T: Sendable>(of promise: Promise<T>, cancellable: Bool = true) async throws -> T {
    let id = ObjectIdentifier(promise)
    let admitted = state.withLock { state in
      guard !state.over else { return false }
      state.waiting[id] = { promise.resolve(.failure(CancellationError())) }
      return true
    }
    guard admitted else { throw CancellationError() }
    defer { state.withLock { _ = $0.waiting.removeValue(forKey: id) } }
    return try await promise.value(cancellable: cancellable)
  }

  /// 等 `task` 的结果：这一代先结束、或调用方被取消，就当场抛出，不等它结束（`task` 照样跑完，结果不用，也不取消它）。
  func outcome<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
    let promise = Promise<T>()
    Task { promise.resolve(await task.result) }
    return try await value(of: promise)
  }
}

/// 一个以后才有的答复，只答一次：谁先答（结果、调用方取消、这一代结束）算谁，后来的不管；答早于等的，等时当场拿到。CueSync 里登记等待者、以后再答的都用它，不另写续体。
/// 只能有一个在等（`value`）；要好几个等同一件事的，各登记一个。
final class Promise<T: Sendable>: Sendable {
  private enum State {
    case idle
    case waiting(CheckedContinuation<T, any Error>)
    case early(Result<T, any Error>)
    case done
  }

  private let state = Mutex(State.idle)

  func resolve(_ result: Result<T, any Error>) {
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

  /// 等答复。`cancellable`：调用方被取消就当场抛出 `CancellationError`（等之前就取消了的也是）；不然等到有人答。
  func value(cancellable: Bool = true) async throws -> T {
    guard cancellable else { return try await wait() }
    return try await withTaskCancellationHandler {
      try await wait()
    } onCancel: {
      resolve(.failure(CancellationError()))
    }
  }

  private func wait() async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
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
  }
}
