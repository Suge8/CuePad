#if os(iOS)
import ActivityKit
import Foundation
import OSLog
import UIKit

/// iPhone 锁屏与灵动岛上的实时活动（格子进度，内容见 `CueActivityState`）：App 在前台且有在管或等你时开一个（只一个），变了就更新，都没了就结束。
/// 没有服务端，内容只由 App 改：前台时库一变就改；后台靠推送把 App 叫起来——等你类的可见推送带 content-available，与同步区的静默推送一样让 App 拉一次
/// （`IOSAppDelegate`），拉到的变化经小组件快照那同一条观察到这里（`AppServices.startSnapshots`），不另起轮询。推送会被系统合并、被划掉的 App 叫不醒，
/// 所以每份都带过时时刻（写下后 `staleAfter`）：过了还没有新的，卡片变淡、写"x 分钟前"，不装作是新的；回到前台、进后台前按此刻重发一次，过时时刻从那时算。
/// 系统只许前台开启，所以后台读到有事时只改已开着的，回前台时再开。
final class CueLiveActivity {
    /// 一份写下后多久算过时。
    static let staleAfter: TimeInterval = 15 * 60
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "live-activity")

    /// 开着的那一个（`Activity.id`）：只记 id，每次用时从系统的列表里取，不把系统的对象留在主线程上跨线程用。
    private var activityID: String?
    /// 最近读到的一份与最近发出去的一份。
    private var latest: CueActivityState?
    private var sent: CueActivityState?
    /// 开、改、结束一件件排着做：每件都要等系统，前一件没做完时下一件读到的开着的那个可能已经不对了。
    private var queue: Task<Void, Never>?
    private var adopted = false

    /// 读到新的一份：内容变了才发；`resend` 时一样也发（过时时刻从此刻算）。返回排着的那件，进后台前要等它做完。
    @discardableResult
    func show(_ state: CueActivityState, resend: Bool = false) -> Task<Void, Never> {
        latest = state
        return enqueue(resend: resend)
    }

    /// 按最近读到的那份重发（回到前台）。
    func resend() { enqueue(resend: true) }

    @discardableResult
    private func enqueue(resend: Bool) -> Task<Void, Never> {
        let previous = queue
        let task = Task {
            await previous?.value
            await self.apply(resend: resend)
        }
        queue = task
        return task
    }

    private func apply(resend: Bool) async {
        if !adopted {
            adopted = true
            activityID = await Self.adopt()
        }
        guard var state = latest else { return }
        state.at = .now
        guard state.isLive else {
            if let activityID { await Self.end(activityID, state) }
            activityID = nil
            sent = nil
            return
        }
        let content = ActivityContent(state: state, staleDate: state.at.addingTimeInterval(Self.staleAfter))
        if let activityID {
            if !resend, let sent, sent.same(as: state) { return }
            if await Self.update(activityID, content) {
                sent = state
                return
            }
        }
        // 没开过，或被划掉、被系统结束了：在前台再开一个
        activityID = nil
        guard UIApplication.shared.applicationState == .active, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            activityID = try Activity.request(attributes: CueActivityAttributes(), content: content).id
            sent = state
        } catch {
            Self.log.error("实时活动没能开启：\(String(describing: error), privacy: .public)")
        }
    }

    private nonisolated static func running(_ id: String) -> Activity<CueActivityAttributes>? {
        Activity<CueActivityAttributes>.activities.first { $0.id == id && [.active, .stale].contains($0.activityState) }
    }

    /// 改开着的那一个；它已经不在了返回 false。
    private nonisolated static func update(_ id: String, _ content: ActivityContent<CueActivityState>) async -> Bool {
        guard let activity = running(id) else { return false }
        await activity.update(content)
        return true
    }

    private nonisolated static func end(_ id: String, _ state: CueActivityState) async {
        await running(id)?.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
    }

    /// 上次运行开着的接着用，多出来的结束：只留一个。
    private nonisolated static func adopt() async -> String? {
        let running = Activity<CueActivityAttributes>.activities
        for extra in running.dropFirst() { await extra.end(nil, dismissalPolicy: .immediate) }
        return running.first?.id
    }
}
#endif
