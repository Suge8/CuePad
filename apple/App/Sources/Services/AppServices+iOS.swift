#if os(iOS)
import CueStore
import Foundation
import UIKit

/// iOS 的后台服务：接收分享入库、维护小组件快照、前台的会话提示。
extension AppServices {
    /// 幂等。
    func start() {
        guard !tasks.isRunning else { return }
        startCaptureIngest()
        startSnapshots()
        startSync()
        startSpeechClock()
        startLiveSessions()
        startAccountQuotas()
        startSessionAlerts()
        if let viewer {
            follow(reporting: { .syncUnavailable("这台手机开着的页没能写下：\($0)") }) { try await viewer.keep() }
        }
        if location.touchesRealWorld { diagnostics.start() }
    }

    /// 前台提示：本机已同步来的在线会话（`LiveSessions`）每次变化，由 `SessionAlertTracker` 认出"等你"、"做完了"，到得了你的（`CueStore.reaches`）交给界面。
    /// 不依赖推送是否到达；App 不在前台时不发（后台由系统推送提示，前台系统不再重复展示，见 `AlertCenter`）。
    private func startSessionAlerts() {
        let active = ActiveSince()
        follow {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { active.date = .now }
        }
        follow {
            var tracker = SessionAlertTracker()
            for await live in Observations({ self.liveSessions.live }) {
                let alerts = tracker.alerts(for: live, cue: self.liveSessions.cue, since: active.date)
                guard UIApplication.shared.applicationState == .active, !alerts.isEmpty else { continue }
                var reaching: [SessionAlert] = []
                for alert in alerts where await self.reaches(.session(alert.session, alert.kind)) { reaching.append(alert) }
                if let alert = reaching.last(where: { $0.kind == .waitingForUser }) ?? reaching.last { self.post(alert) }
            }
        }
    }
}

/// 这次回到前台的时刻（启动即算一次）：前台提示只报它之后的转换（`SessionAlertTracker`）。
private final class ActiveSince {
    var date = Date()
}
#endif
