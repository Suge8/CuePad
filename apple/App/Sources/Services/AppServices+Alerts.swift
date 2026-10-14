#if os(macOS)
import CueStore
import Foundation

/// Mac 的提示与 Dock 角标。来源只有同步来的状态，不收推送（docs/sync.md「Agent 与 Cue 的通知」）。
extension AppServices {
    /// - Agent：不分会话在本机还是别的 Mac，同一条路——在线会话（`LiveSessions`）每次变化，`SessionAlertTracker` 认出转换
    ///   （本次运行第一次读到的只记基线），逐条交给 `AlertCenter.post`。Cue 的由 `CueService.followNotifications` 读库发。
    /// - Dock 角标是"等你"的总数（`CueWaiting`，"等你 N"同一处）。
    func startAlerts() {
        guard let alerts else { return }
        follow {
            var tracker = SessionAlertTracker()
            for await live in Observations({ self.liveSessions.live }) {
                // 不等发完：第一次要征求权限时系统提示可能停很久，这期间的转换照样要认出来
                for alert in tracker.alerts(for: live) { Task { await alerts.post(AlertMessage(alert)) } }
            }
        }
        follow(reporting: { .syncUnavailable("Dock 角标没能读出等你的数：\($0)") }) {
            for try await count in self.store.observe({ try CueWaiting.read(in: $0).count }) { await alerts.showBadge(count) }
        }
    }
}
#endif
