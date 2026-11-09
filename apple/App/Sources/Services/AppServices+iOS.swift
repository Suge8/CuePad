#if os(iOS)
import CueStore
import Foundation
import UIKit

extension AppServices {
    /// 幂等。
    func start() {
        guard !tasks.isRunning else { return }
        startCaptureIngest()
        startStrayFileCleanup()
        startSnapshots()
        startSync()
        startRelay()
        startSpeechClock()
        startLiveSessions()
        startAccountQuotas()
        startForeground()
        if let viewer {
            follow(reporting: { .syncUnavailable(String(localized: "这台手机开着的页没能写下：\(String(describing: $0))")) }) { try await viewer.keep() }
            followArrivals(viewer)
        }
        startDiagnostics()
    }

    /// 整个 App 只订这一份，iPad 开几个窗口都只做一次。立即同步排最前：它的拉取当场在主线程之外开始，不排在别的事的主线程工作后面。
    /// 不等上一次回前台的做完：一次立即同步拉得久时，下一次回前台照样当场记时刻、开拉。
    /// 启动那次由各自的启动路径做，这里订上之前的那次激活收不到也不缺。
    private func startForeground() {
        let active = ActiveSince()
        follow {
            await withDiscardingTaskGroup { group in
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    active.date = .now
                    // 主线程隔离的函数值作子任务，按加入的先后排上主线程；写成 `{ @MainActor in … }` 闭包时 Swift 6.4 的区域隔离检查报内部错误
                    let steps: [@MainActor @Sendable () async -> Void] = [self.handleActivation, self.refreshAlerts, self.drainCaptures, self.resendSnapshots]
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

    /// 用户可能在系统设置里改过通知权限。
    private func refreshAlerts() async {
        await alerts?.refresh()
    }

    /// 不依赖推送是否到达；App 不在前台时不发（后台由系统推送提示，前台系统不再重复展示，见 `AlertCenter`）。
    private func startSessionAlerts(since active: ActiveSince) {
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
