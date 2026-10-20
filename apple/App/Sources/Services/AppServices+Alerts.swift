#if os(macOS)
import CueStore
import Foundation

/// Mac 的提示与 Dock 角标。来源只有同步来的状态，不收推送（docs/sync.md「Agent 与 Cue 的通知」）。
extension AppServices {
    /// - Agent：不分会话在本机还是别的 Mac，同一条路——在线会话（`LiveSessions`）每次变化，`SessionAlertTracker` 认出可能要提示的动静
    ///   （本次运行第一次读到的只记基线），逐条交给 `AlertCenter.post`（到不到你在那里问）。Cue 的由 `CueService.followNotifications` 读库发。
    /// - Cue 留给你回的停下：状态没变，会话记录上的手机推送标志由会话所在的这台 Mac 补上（`CueStore.flagLeftToYou`）。
    /// - Dock 角标是"等你"的件数（`CueStore.cueTally`，"等你 N"同一处）。
    func startAlerts() {
        follow(reporting: { .syncUnavailable("Cue 留给你回的会话没能推到手机：\($0)") }) { [store, sync, hostID] in
            var known: Set<CueLeft>?
            for try await left in store.observe({ Set(try $0.cueDuty()?.left ?? []) }) {
                defer { known = left }
                guard let known else { continue }
                for entry in left.subtracting(known) {
                    if let id = try await store.flagLeftToYou(entry, host: hostID) { await sync?.upload(id) }
                }
            }
        }
        guard let alerts else { return }
        follow {
            var tracker = SessionAlertTracker()
            for await live in Observations({ self.liveSessions.live }) {
                // 不等发完：第一次要征求权限时系统提示可能停很久，这期间的转换照样要认出来
                for alert in tracker.alerts(for: live, cue: self.liveSessions.cue) { Task { await alerts.post(AlertMessage(alert)) } }
            }
        }
        follow(reporting: { .syncUnavailable("Dock 角标没能读出等你的数：\($0)") }) {
            for try await count in self.store.observe({ try $0.cueTally().waiting.count }) { await alerts.showBadge(count) }
        }
    }
}
#endif
