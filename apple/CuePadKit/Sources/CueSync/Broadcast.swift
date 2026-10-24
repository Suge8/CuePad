import Synchronization

/// 一处发、多处收：每个订阅者一条自己的 AsyncStream，订阅结束时自己移除。`replaysLatest` 的新订阅者先拿到最近一个值。
final class Broadcast<Element: Sendable>: Sendable {
  private struct State {
    var latest: Element?
    var subscribers: [Int: AsyncStream<Element>.Continuation] = [:]
    var next = 0
  }

  private let state: Mutex<State>
  private let replaysLatest: Bool
  private let policy: AsyncStream<Element>.Continuation.BufferingPolicy

  init(latest: Element? = nil, bufferingPolicy policy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded) {
    state = Mutex(State(latest: latest))
    replaysLatest = latest != nil
    self.policy = policy
  }

  func stream() -> AsyncStream<Element> {
    let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: policy)
    let id = state.withLock { state in
      defer { state.next += 1 }
      state.subscribers[state.next] = continuation
      if replaysLatest, let latest = state.latest { continuation.yield(latest) }
      return state.next
    }
    continuation.onTermination = { [weak self] _ in self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) } }
    return stream
  }

  func yield(_ value: Element) {
    state.withLock { state in
      state.latest = value
      for subscriber in state.subscribers.values { subscriber.yield(value) }
    }
  }
}
