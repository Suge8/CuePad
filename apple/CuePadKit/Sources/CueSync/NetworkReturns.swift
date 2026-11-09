import CueStore
import Foundation
import Network
import Synchronization

/// 网络路径可用了：每次路径更新为可用时给一个（不补之前的）。整个进程一个路径监视器，第一次用到时开始。
public enum NetworkReturns {
  public static func stream() -> AsyncStream<Void> { monitor.returns.stream() }

  static var isMetered: Bool { monitor.metered.load(ordering: .relaxed) }

  private static let monitor = Monitor()

  static func simulateReturn() { monitor.returns.yield(()) }

  private final class Monitor: Sendable {
    let returns = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
    let metered = Atomic(false)
    private let path = NWPathMonitor()
    /// 开始时报的第一次是此刻的路径，不是回来了：拿它当网络回来，认不了账号的会当场多认一次。
    private let started = Atomic(false)

    init() {
      path.pathUpdateHandler = { update in  // 监视器整个进程一个，不释放
        self.metered.store(update.isExpensive || update.isConstrained, ordering: .relaxed)
        let first = !self.started.exchange(true, ordering: .relaxed)
        if update.status == .satisfied, !first { self.returns.yield(()) }
      }
      path.start(queue: DispatchQueue(label: "\(AppIdentity.id).network"))
    }
  }
}
