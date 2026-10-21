#if os(macOS)
import Foundation
import Synchronization

/// 测试里起的 `Process` 等它退出只经这里：退出码由 `terminationHandler` 交出（起之前装好，不会错过）。
/// 不用 `waitUntilExit`：它在调用线程上转 RunLoop 等退出通知，在 Swift 并发的线程上会漏掉、子进程早已退出仍永远等着，
/// 而且同步阻塞，测试的时限打断不了（几十个任务并发地起 `cat`、关输入、`waitUntilExit`，两三万次内必卡）。
public final class ProcessExit: Sendable {
  private struct State {
    var status: Int32?
    var waiters: [UUID: @Sendable (Int32?) -> Void] = [:]
  }
  private let state = Mutex(State())

  /// 装好退出回调再起 `process`。
  public init(launching process: Process) throws {
    process.terminationHandler = { [self] process in
      let status = process.terminationStatus
      let waiters = self.state.withLock { state in
        state.status = status
        defer { state.waiters = [:] }
        return state.waiters.values
      }
      for waiter in waiters { waiter(status) }
    }
    try process.run()
  }

  public var value: Int32 { get async { await value(within: nil)! } }

  /// 至多等 `limit`（nil 不限），没退出为 nil。
  public func value(within limit: Duration?) async -> Int32? {
    await withCheckedContinuation { continuation in
      let id = when { continuation.resume(returning: $0) }
      guard let id, let limit else { return }
      Task {
        try? await Task.sleep(for: limit)
        self.state.withLock { $0.waiters.removeValue(forKey: id) }?(nil)
      }
    }
  }

  /// 同步等到退出（不能 await 的地方用，如静态初始化）：信号量由退出回调放开，不靠 RunLoop。
  public var blockingValue: Int32 {
    let exited = DispatchSemaphore(value: 0)
    let box = StatusBox()
    _ = when { value in
      box.status = value ?? -1
      exited.signal()
    }
    exited.wait()
    return box.status
  }

  /// 信号量前后各写一次、读一次，不会同时访问
  private final class StatusBox: @unchecked Sendable { var status: Int32 = -1 }

  /// 退出时调 `waiter`；已经退出就马上调。返回登记的 id（马上调了为 nil）。
  private func when(_ waiter: @escaping @Sendable (Int32?) -> Void) -> UUID? {
    let id = UUID()
    let status = state.withLock { state in
      if state.status == nil { state.waiters[id] = waiter }
      return state.status
    }
    guard let status else { return id }
    waiter(status)
    return nil
  }
}

extension Process {
  public func runToExit() async throws -> Int32 {
    try await ProcessExit(launching: self).value
  }
}
#endif
