import Foundation
import Synchronization

struct Owned: Sendable {
  let id: UUID
  let task: Task<Void, Never>

  static func spawn(@_inheritActorContext _ body: @escaping @Sendable (UUID) async -> Void) -> Owned {
    let id = UUID()
    return Owned(id: id, task: Task { await body(id) })
  }
}

struct Slots<Key: Hashable> {
  private var owned: [Key: Owned] = [:]

  func has(_ key: Key) -> Bool { owned[key] != nil }

  mutating func put(_ key: Key, _ task: Owned) { owned[key] = task }

  @discardableResult
  mutating func release(_ key: Key, _ id: UUID) -> Bool {
    guard owned[key]?.id == id else { return false }
    owned[key] = nil
    return true
  }

  mutating func cancel(_ key: Key) { owned.removeValue(forKey: key)?.task.cancel() }

  mutating func cancelAll() -> [Task<Void, Never>] {
    let tasks = owned.values.map(\.task)
    tasks.forEach { $0.cancel() }
    owned = [:]
    return tasks
  }
}

/// 等一个可能不响应取消的外部回调（取附件、等目标就绪），但取消时不等它：立即抛 `CancellationError`，回调留在脱离的任务里自己收尾，结果丢弃。
/// 任务组退出、`stop()` 都要等子任务真正结束，不隔开的话一个不返回的回调会让它们永久挂住。
public func abandonable<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
  let handoff = Handoff<T>()
  return try await withTaskCancellationHandler {
    try await handoff.run(operation)
  } onCancel: {
    handoff.cancel()
  }
}

private final class Handoff<T: Sendable>: Sendable {
  private struct State {
    var continuation: CheckedContinuation<T, any Error>?
    var worker: Task<Void, Never>?
    var finished = false
  }
  private let state = Mutex(State())

  func run(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      let cancelled = state.withLock { state -> Bool in
        if state.finished { return true }
        state.continuation = continuation
        return false
      }
      if cancelled { return continuation.resume(throwing: CancellationError()) }
      let worker = Task {
        do { complete(.success(try await operation())) } catch { complete(.failure(error)) }
      }
      let late = state.withLock { state -> Bool in
        if state.finished { return true }
        state.worker = worker
        return false
      }
      if late { worker.cancel() }
    }
  }

  func cancel() {
    let (continuation, worker) = take()
    worker?.cancel()
    continuation?.resume(throwing: CancellationError())
  }

  private func complete(_ result: Result<T, any Error>) {
    take().continuation?.resume(with: result)
  }

  private func take() -> (continuation: CheckedContinuation<T, any Error>?, worker: Task<Void, Never>?) {
    state.withLock { state in
      guard !state.finished else { return (nil, nil) }
      state.finished = true
      defer { state.continuation = nil; state.worker = nil }
      return (state.continuation, state.worker)
    }
  }
}
