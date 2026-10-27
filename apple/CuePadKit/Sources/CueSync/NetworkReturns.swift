import CueStore
import Foundation
import Network
import Synchronization

/// 网络路径可用了：每次路径更新为可用时给一个（不补之前的）。连不上时在退避的据此提前再试——同步层的重试调度（`SyncCoordinator+Hold`，经 `CloudSync`）与 App 的门铃重连；
/// 手机换了网（蜂窝换成 Wi-Fi）时文件那一路据此再看要不要自动取（`FileFetcher`）。整个进程一个路径监视器，第一次用到时开始。
public enum NetworkReturns {
  public static func stream() -> AsyncStream<Void> { monitor.returns.stream() }

  /// 此刻的网络按流量计费或受限：蜂窝、个人热点（`isExpensive`），或低数据模式（`isConstrained`）。
  static var isMetered: Bool { monitor.metered.load(ordering: .relaxed) }

  private static let monitor = Monitor()

  /// 同步测量的断网恢复（`CloudOutage`）：路径监视器不知道那次断开，替它报一次网络回来。
  static func simulateReturn() { monitor.returns.yield(()) }

  private final class Monitor: Sendable {
    let returns = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
    let metered = Atomic(false)
    private let path = NWPathMonitor()

    init() {
      path.pathUpdateHandler = { update in  // 监视器整个进程一个，不释放
        self.metered.store(update.isExpensive || update.isConstrained, ordering: .relaxed)
        if update.status == .satisfied { self.returns.yield(()) }
      }
      path.start(queue: DispatchQueue(label: "\(AppIdentity.id).network"))
    }
  }
}
