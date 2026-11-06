import Foundation
import Synchronization

/// 带身份的后台任务：actor 里登记任务的位置，只认身份，不认"位置上有没有东西"。
/// 任务晚到的收尾（sleep 已返回才发现被取消、停止后才跑完）只能清走自己占的位置（`Slots.release`、`Pace.due`：身份相同才算），
/// 碰不到后来登记在同一位置的新任务。本模块所有"任务晚于登记它的状态才收尾"的地方都走这一种写法，不另写代次计数。
struct Owned: Sendable {
  let id: UUID
  let task: Task<Void, Never>

  /// 起任务；`body` 拿到自己的身份，收尾时交回登记处核对。
  static func spawn(@_inheritActorContext _ body: @escaping @Sendable (UUID) async -> Void) -> Owned {
    let id = UUID()
    return Owned(id: id, task: Task { await body(id) })
  }
}

/// actor 里按键登记的任务。
struct Slots<Key: Hashable> {
  private var owned: [Key: Owned] = [:]

  func has(_ key: Key) -> Bool { owned[key] != nil }

  mutating func put(_ key: Key, _ task: Owned) { owned[key] = task }

  /// 任务收尾：位置上还是自己才清，返回是否清了；已被停止清空或换成别的任务就什么都不动。
  @discardableResult
  mutating func release(_ key: Key, _ id: UUID) -> Bool {
    guard owned[key]?.id == id else { return false }
    owned[key] = nil
    return true
  }

  /// 取消并清掉这个位置（不等它）。
  mutating func cancel(_ key: Key) { owned.removeValue(forKey: key)?.task.cancel() }

  /// 取消全部并清空，返回它们的任务让调用方等收尾。
  mutating func cancelAll() -> [Task<Void, Never>] {
    let tasks = owned.values.map(\.task)
    tasks.forEach { $0.cancel() }
    owned = [:]
    return tasks
  }
}

/// 等一个可能不响应取消的外部回调（取附件、等目标就绪），但取消时不等它：立即抛 `CancellationError`，回调留在脱离的任务里自己收尾，结果丢弃。
/// 任务组退出、`stop()` 都要等子任务真正结束，不隔开的话一个不返回的回调会让它们永久挂住。
func abandonable<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
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
        if state.finished { return true }  // 还没开始就被取消了
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
