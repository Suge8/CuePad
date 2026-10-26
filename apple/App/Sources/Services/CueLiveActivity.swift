#if os(iOS)
import ActivityKit
import CueStore
import Foundation
import OSLog

/// iPhone 锁屏与灵动岛上的实时活动（内容见 `CueActivityState`）：有活（`CueNow.isLive`：Cue 在一轮里、有在跑或等子代理的、有等你的）且 App 在前台时开一个（只一个），
/// 变了就更新，没活了带着最后一份结束：刚做完一件时那一份在锁屏留到那颗收掉（`CueNow.doneWindow`），否则当场收起。
/// 没有服务端，内容只由 App 改，每次都是当场从库推出的那一份（`AppServices.writeSnapshots`），这里不另存：前台时库一变就改（`AppServices.startSnapshots`）；
/// 后台靠推送把 App 叫起来——Cue 的话、进了等你的会话总有一条推送（到得了你的是带 content-available 的可见推送，你正在 Mac 上看着的是静默推送，`CuePush`、`PiPush`），
/// 让 App 拉一次，拉完当场改（`IOSAppDelegate`），不另起轮询。
/// 推送会被系统合并、被划掉的 App 叫不醒，所以按时刻会变的交给系统：每份的 `staleDate` 是它下一次变的那一刻（`CueNow.nextShownChange`：
/// 过时、刚做完的收掉），系统到点重画，画的是那一份到那时的样子（`CueActivityViews`）；走秒的计时也交给系统（`Text(timerInterval:)`）。
/// 系统只许前台开启，所以后台读到有事时只改已开着的，回前台时再开。和系统里那一份一样就不发（`same`，不看推出的时刻），`resend` 时照发（过时时刻从此刻算）。
final class CueLiveActivity {
    private static let log = Logger(subsystem: AppIdentity.id, category: "live-activity")

    /// 上次运行开着的接着用，多出来的结束：只留一个。
    init() {
        Task {
            for extra in Self.running.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// 读到的此刻那一份。`foreground`：App 此刻在前台，没开着就开一个。
    func show(_ state: CueActivityState, resend: Bool, foreground: Bool) async {
        let now = state.now
        let running = Self.running.first
        guard now.isLive else {
            let done = now.nextChange(after: now.at)
            await running?.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: done.map { .after($0) } ?? .immediate)
            return
        }
        let content = ActivityContent(state: state, staleDate: now.nextShownChange(after: now.at) ?? now.staleAt)
        if let running {
            if !resend, running.content.state.same(as: state) { return }
            await running.update(content)
            return
        }
        // 没开过，或被划掉、被系统结束了：在前台再开一个
        guard foreground, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(attributes: CueActivityAttributes(), content: content)
        } catch {
            Self.log.error("实时活动没能开启：\(String(describing: error), privacy: .public)")
        }
    }

    /// 不随主线程隔离：取到的系统对象才能交给它自己的异步方法（`update`、`end`）。
    private nonisolated static var running: [Activity<CueActivityAttributes>] {
        Activity<CueActivityAttributes>.activities.filter { [.active, .stale].contains($0.activityState) }
    }
}
#endif
