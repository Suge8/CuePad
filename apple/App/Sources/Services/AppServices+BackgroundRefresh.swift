#if os(iOS)
import UIKit

extension AppServices {
    /// 后台推送的一拉不经过界面的忙碌时限，也不能吞掉拉取错误再向系统报成功。
    /// 拉到的一部分也要发布：之后是否还有执行机会由系统决定，不依赖观察任务的调度。
    func refreshFromPush() async -> UIBackgroundFetchResult {
        guard let sync else { return .noData }
        let result: UIBackgroundFetchResult
        do {
            result = switch try await sync.syncNow() {
            case .newData: .newData
            case .noData: .noData
            case .incomplete: .failed
            }
        } catch {
            result = .failed
        }
        // 系统交还后可能当场挂起，等不到观察：别处看过的通知在这里收（`AlertCenter.dismissSeen`）
        if let marks = try? await store.sessionMarks() { await alerts?.dismissSeen(marks) }
        do {
            try await snapshots.writeSnapshots()
        } catch {
            reportIssue(.widgetDataUnavailable("\(error)"))
            return .failed
        }
        return result
    }
}
#endif
