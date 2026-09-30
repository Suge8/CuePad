#if os(iOS)
import Foundation

/// iOS 的后台服务：接收分享入库、维护小组件快照。
extension AppServices {
    /// 幂等。
    func start() {
        guard tasks.isEmpty else { return }
        startCaptureIngest()
        startSnapshots()
        startSync()
    }
}
#endif
