import Synchronization

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

  func outcome<T: Sendable>(of task: Task<T, any Error>) async throws -> T {
    let promise = Promise<T>()
    Task { promise.resolve(await task.result) }
    return try await value(of: promise)
  }
}

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
