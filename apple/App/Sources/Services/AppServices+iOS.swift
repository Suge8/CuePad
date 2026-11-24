#if os(iOS)
import CueStore
import Foundation
import UIKit

extension AppServices {
    func start() {
        guard !tasks.isRunning else { return }
        startCaptureIngest()
        startStrayFileCleanup()
        startDeliveryCleanup()
        startSnapshots()
        startSync()
        startRelay()
        startSpeechClock()
        startSessionFeed()
        startAccountQuotas()
        startForeground()
        follow(reporting: { .syncUnavailable(String(localized: "这台手机开着的页没能写下：\(String(describing: $0))")) }) { [viewer] in try await viewer.keep() }
        followArrivals(viewer)
        startDiagnostics()
        follow { for await ready in Observations({ self.knowsActivityState }) where ready { await self.cueActivity?.syncReady() } }
    }

    private func startForeground() {
        let active = ActiveSince()
        follow {
            await withDiscardingTaskGroup { group in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {  // 晚订：启动那次激活由启动路径做，早订会收到它、启动时多做一遍
                    active.date = .now
                    // 主线程隔离的函数值作子任务，按加入的先后排上主线程；写成 `{ @MainActor in … }` 闭包时 Swift 6.4 的区域隔离检查报内部错误
                    let steps: [@MainActor @Sendable () async -> Void] = [self.handleActivation, self.refreshAlerts, self.captures.drainCaptures, self.resendSnapshots]
                    for step in steps { group.addTask(operation: step) }
                }
            }
        }
        startSessionAlerts(since: active)
    }

    /// 他来到这台只在这里记：启动时 App 就在前台（他点开的，不是推送在后台叫起来的）记一次，之后每次从后台回到前台各记一次。
    /// 按回到前台（`willEnterForeground`）而不是变活跃：冷启动不发它，与启动那次不重；拉下控制中心再收起这类短暂失活也不算离开过这台。
    private func followArrivals(_ viewer: ViewerKeeper) {
        let launchedInFront = UIApplication.shared.applicationState != .background
        let returns = NotificationCenter.default.notifications(named: UIApplication.willEnterForegroundNotification)
        follow {
            if launchedInFront { await viewer.arrive() }
            for await _ in returns { await viewer.arrive() }
        }
    }

    private func refreshAlerts() async {
        await alerts?.refresh()
        await alerts?.dismissSeen(sessionFeed.marks)
    }

    private func startSessionAlerts(since active: ActiveSince) {
        follow {
            var tracker = SessionAlertTracker()
            for await live in Observations({ self.sessionFeed.live }) {
                let alerts = tracker.alerts(for: live, cue: self.sessionFeed.cue, since: active.date)
                guard UIApplication.shared.applicationState == .active, !alerts.isEmpty else { continue }
                var reaching: [SessionAlert] = []
                for alert in alerts where await self.reaches(.session(alert.session, alert.kind)) { reaching.append(alert) }
                if let alert = reaching.last(where: { $0.kind == .waitingForUser }) ?? reaching.last { self.post(alert) }
            }
        }
    }
}

private final class ActiveSince {
    var date = Date()
}
#endif
