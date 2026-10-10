#if os(iOS)
import CueStore
import Foundation
import UIKit

/// iOS 的后台服务：接收分享入库、维护小组件快照、前台的会话提示。
extension AppServices {
    /// 幂等。
    func start() {
        guard tasks.isEmpty else { return }
        startCaptureIngest()
        startSnapshots()
        startSync()
        startSessionAlerts()
        if !location.isIsolated { diagnostics.start() }
    }

    /// 前台提示：本机已同步来的在线会话每次变化，由 `SessionAlertTracker` 认出"等你确认"、"做完了"的转换，交给界面。
    /// 不依赖推送是否到达；App 不在前台时不发（后台由系统推送提示，前台系统不再重复展示，见 `PiAlertCenter`）。
    private func startSessionAlerts() {
        let active = ActiveSince()
        tasks.append(Task {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { active.date = .now }
        })
        tasks.append(Task {
            var tracker = SessionAlertTracker()
            let live = store.observe { try $0.piSessionPage(PiSessionQuery(scope: .live, limit: .max)).items.map(\.state) }
            do {
                for try await states in live {
                    let alerts = tracker.alerts(for: states, since: active.date)
                    guard UIApplication.shared.applicationState == .active else { continue }
                    if let alert = alerts.last(where: { $0.kind == .waitingForUser }) ?? alerts.last { post(alert) }
                }
            } catch {
                reportIssue(.syncUnavailable("读取在线会话失败，前台不再提示会话变化：\(error)"))
            }
        })
    }
}

/// 这次回到前台的时刻（启动即算一次）：前台提示只报它之后的转换（`SessionAlertTracker`）。
@MainActor
private final class ActiveSince {
    var date = Date()
}
#endif
