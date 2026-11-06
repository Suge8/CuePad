import Synchronization

/// 一处发、多处收：每个订阅者一条自己的 AsyncStream，`replaysLatest` 的新订阅者先拿到最近一个值。
/// 结束了的订阅在下一次发的时候移除，不用 `onTermination`：取消订阅时 AsyncStream 持着自己的锁调它，它再拿这里的锁，
/// 而发的时候是持着这里的锁去拿流的锁，两边顺序相反会互等（取消订阅碰上发，实测卡死）。
final class Broadcast<Element: Sendable>: Sendable {
  private struct State {
    var latest: Element?
    var subscribers: [AsyncStream<Element>.Continuation] = []
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
    state.withLock { state in
      state.subscribers.append(continuation)
      if replaysLatest, let latest = state.latest { continuation.yield(latest) }
    }
    return stream
  }

  func yield(_ value: Element) {
    state.withLock { state in
      state.latest = value
      state.subscribers.removeAll { subscriber in
        if case .terminated = subscriber.yield(value) { true } else { false }
      }
    }
  }
}
