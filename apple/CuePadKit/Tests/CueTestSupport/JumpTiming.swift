import CueStore
import Foundation
import Synchronization

public final class JumpTiming: Sendable {
  private struct State {
    var skipped: TimeInterval = 0
    var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
  }
  private let state = Mutex(State())

  public init() {}

  public var now: Date { Date().addingTimeInterval(state.withLock { $0.skipped }) }
  public var timing: Timing {
    Timing(
      now: { self.now }, sleep: { try await self.sleep(until: self.now.addingTimeInterval($0.seconds)) },
      sleepUntil: { try await self.sleep(until: $0) })
  }

  public func jump(by duration: Duration) {
    let woken = state.withLock { state in
      state.skipped += duration.seconds
      defer { state.waiters = [:] }
      return Array(state.waiters.values)
    }
    for waiter in woken { waiter.resume() }
  }

  private func sleep(until deadline: Date) async throws {
    while true {
      try Task.checkCancellation()
      let (skipped, left) = state.withLock { ($0.skipped, deadline.timeIntervalSince(Date().addingTimeInterval($0.skipped))) }
      guard left > 0 else { return }
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await Task.sleep(for: .seconds(left)) }
        group.addTask { await self.jumped(since: skipped) }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
    }
  }

  private func jumped(since skipped: TimeInterval) async {
    let id = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let ready = state.withLock { state in
          if state.skipped != skipped || Task.isCancelled { return true }
          state.waiters[id] = continuation
          return false
        }
        if ready { continuation.resume() }
      }
    } onCancel: {
      state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
    }
  }
}
