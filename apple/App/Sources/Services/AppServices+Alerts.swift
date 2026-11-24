#if os(macOS)
import CueStore
import Foundation

extension AppServices {
    func startAlerts() {
        follow(reporting: { .syncUnavailable(String(localized: "Cue 留给你回的会话没能推到手机：\(String(describing: $0))")) }) { [store, hostID] in
            var known: Set<CueLeft>?
            for try await left in store.observe({ try $0.sessionsLeftToYou() }) {
                defer { known = left }
                guard let known else { continue }
                for entry in left.subtracting(known) {
                    try await store.flagLeftToYou(entry, host: hostID)
                }
            }
        }
        guard let alerts else { return }
        follow {
            var tracker = SessionAlertTracker()
            for await live in Observations({ self.sessionFeed.live }) {
                // 不等发完：第一次要征求权限时系统提示可能停很久，这期间的转换照样要认出来
                for alert in tracker.alerts(for: live, cue: self.sessionFeed.cue) { Task { await alerts.post(AlertMessage(alert)) } }
            }
        }
    }
}
#endif
