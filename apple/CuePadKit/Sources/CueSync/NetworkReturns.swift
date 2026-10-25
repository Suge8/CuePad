import CueStore
import Foundation
import Network

/// 网络路径可用了：每次路径更新为可用时给一个（不补之前的）。连不上时在退避的据此提前再试——发送者（`RecordSender`）与 App 的门铃重连。
/// 整个进程一个路径监视器，第一次订阅时开始。
public enum NetworkReturns {
  public static func stream() -> AsyncStream<Void> { monitor.returns.stream() }

  private static let monitor = Monitor()

  private final class Monitor: Sendable {
    let returns = Broadcast<Void>(bufferingPolicy: .bufferingNewest(1))
    private let path = NWPathMonitor()

    init() {
      path.pathUpdateHandler = { [returns] update in
        if update.status == .satisfied { returns.yield(()) }
      }
      path.start(queue: DispatchQueue(label: "\(AppIdentity.id).network"))
    }
  }
}
