#if os(iOS)
import CueStore
import Foundation
import UIKit

/// iOS 的后台服务：接收分享入库、维护小组件快照、回到前台、前台的会话提示。
extension AppServices {
    /// 幂等。
    func start() {
        guard !tasks.isRunning else { return }
        startCaptureIngest()
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
        if location.touchesRealWorld { diagnostics.start() }
    }

    /// 回到前台（整个 App 只订这一份，iPad 开几个窗口都只做一次）：当场记下回前台的时刻，先开立即同步（`handleActivation`：恢复按节奏拉、重连门铃、拉一次），
    /// 再刷新通知设置、收分享、重发实时活动，这几件不分先后。立即同步排最前：它的拉取当场在主线程之外开始，不排在别的事的主线程工作后面。
    /// 不等上一次回前台的做完：一次立即同步拉得久时，下一次回前台照样当场记时刻、开拉。
    /// 启动那次由各自的启动路径做（`startSync`、`startCaptureIngest`、`AlertCenter.enable`、快照的第一份），这里订上之前的那次激活收不到也不缺。
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

    /// 他来到这台（`ViewerKeeper.arrive`）只在这里记：启动时 App 就在前台（他点开的，不是推送在后台叫起来的）记一次，之后每次从后台回到前台各记一次。
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

    /// 实时活动只能在前台开：回到前台时按库里此刻推一份，再看一次要不要开，过时时刻从此刻算。
    private func resendSnapshots() async {
        guard cueActivity != nil else { return }
        do {
            try await writeSnapshots(resend: true)
        } catch {
            reportIssue(.widgetDataUnavailable("\(error)"))
        }
    }

    /// 前台提示：本机已同步来的在线会话（`LiveSessions`）每次变化，由 `SessionAlertTracker` 认出"等你"、"做完了"，到得了你的（`CueStore.reaches`）交给界面。
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
