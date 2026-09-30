import Foundation

/// 同步时序记录：每条记录何时上传完成、何时随一次拉取被应用（含该次拉取的开始时刻）。延迟测量用；只保留最近的若干条。
public actor SyncTimingLog {
  public struct Fetch: Equatable, Sendable {
    /// 该次拉取开始的时刻；引擎没有报告时为 nil。
    public var startedAt: Date?
    public var appliedAt: Date
  }

  private static let limit = 2_000
  private var fetches: [String: Fetch] = [:]
  private var sends: [String: Date] = [:]
  private var order: [String] = []
  private var waiters: [String: [(id: UUID, continuation: CheckedContinuation<Fetch?, Never>)]] = [:]

  public init() {}

  public func fetch(of recordName: String) -> Fetch? { fetches[recordName] }
  public func send(of recordName: String) -> Date? { sends[recordName] }

  /// 等到这条记录被某次拉取应用；任务被取消时返回 nil（调用方用超时取消它）。
  public func waitForFetch(of recordName: String) async -> Fetch? {
    if let known = fetches[recordName] { return known }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // 取消可能发生在登记之前（此时 onCancel 找不到这个等待者），所以登记时要再看一次
        if Task.isCancelled {
          continuation.resume(returning: nil)
        } else {
          waiters[recordName, default: []].append((id, continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id, recordName) }
    }
  }

  func recordFetch(_ names: [String], startedAt: Date?, appliedAt: Date) {
    let entry = Fetch(startedAt: startedAt, appliedAt: appliedAt)
    for name in names {
      remember(name)
      fetches[name] = entry
      for waiter in waiters.removeValue(forKey: name) ?? [] { waiter.continuation.resume(returning: entry) }
    }
  }

  func recordSend(_ names: [String], at time: Date) {
    for name in names {
      remember(name)
      sends[name] = time
    }
  }

  private func remember(_ name: String) {
    order.append(name)
    if order.count > Self.limit * 2 {
      for old in order.prefix(Self.limit) {
        fetches[old] = nil
        sends[old] = nil
      }
      order.removeFirst(Self.limit)
    }
  }

  private func cancelWaiter(_ id: UUID, _ name: String) {
    guard let index = waiters[name]?.firstIndex(where: { $0.id == id }) else { return }
    waiters[name]?.remove(at: index).continuation.resume(returning: nil)
  }
}
