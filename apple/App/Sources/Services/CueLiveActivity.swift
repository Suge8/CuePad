#if os(iOS)
import ActivityKit
import CueStore
import Foundation
import OSLog

/// iPhone 上只开一个实时活动。有真实同步时请求推送令牌，内容与结束由 Mac 经 APNs 独占写入；
/// 本地库可能落后于系统刚收到的推送，不能在回前台、后台拉取或回答后拿本地快照覆盖它。
/// 隔离演示没有远程发布者，才由本地更新与结束。系统只允许前台开启，八小时结束后也要回到前台再开。
/// 令牌的初值、轮换与结束在同一服务维护（`CueLiveActivity+Destination`），不等待窗口或下一次前台激活。
final class CueLiveActivity {
    static let log = Logger(subsystem: AppIdentity.id, category: "live-activity")
    let store: CueStore
    let sync: (any SyncControlling)?
    let device: String?
    private var restoration: Task<Void, Never>?
    var observers: [String: [Task<Void, Never>]] = [:]

    init(store: CueStore, sync: (any SyncControlling)?, device: String?) {
        self.store = store
        self.sync = sync
        self.device = device
        restoration = Task { await restore() }
    }

    isolated deinit {
        restoration?.cancel()
        for tasks in observers.values { for task in tasks { task.cancel() } }
    }

    private func restore() async {
        let activities = Self.running
        for extra in activities.dropFirst() {
            await extra.end(nil, dismissalPolicy: .immediate, timestamp: .now)
            await removeDestination(activityID: extra.id)
        }
        if let activity = activities.first, activity.attributes.remoteUpdates == true {
            observe(activity)
        } else {
            await removeDestination(activityID: nil)
        }
    }

    /// `foreground` 只决定能否开启，不把“允许本地写”与是否在前台混为一谈。
    func show(_ state: CueActivityState, resend: Bool, foreground: Bool) async {
        await restoration?.value
        var running = Self.running.first
        // 远程活动即使令牌尚未生成或这一刻不同步，也不能由本地库接管内容。
        if running?.attributes.remoteUpdates == true { return }
        if sync != nil, let old = running {
            guard foreground else { return }
            await old.end(nil, dismissalPolicy: .immediate, timestamp: state.now.at)
            running = Self.running.first
            if running?.attributes.remoteUpdates == true { return }
        }
        let now = state.now
        guard now.isLive else {
            let done = now.nextChange(after: now.at)
            await running?.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: done.map { .after($0) } ?? .immediate, timestamp: now.at)
            return
        }
        let content = ActivityContent(state: state, staleDate: now.nextShownChange(after: now.at) ?? now.staleAt)
        if let running {
            guard resend || !running.content.state.same(as: state) else { return }
            await running.update(content, timestamp: now.at)
            return
        }
        guard foreground, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if sync != nil, device == nil || pushEnvironment == nil {
            Self.log.error("实时活动没有设备标识或推送环境，未开启")
            return
        }
        do {
            let activity = try Activity.request(
                attributes: CueActivityAttributes(remoteUpdates: sync != nil), content: content, pushType: sync == nil ? nil : .token)
            if sync != nil { observe(activity) }
        } catch {
            Self.log.error("实时活动没能开启：\(String(describing: error), privacy: .public)")
        }
    }

    nonisolated static var running: [Activity<CueActivityAttributes>] {
        Activity<CueActivityAttributes>.activities
            .filter { [.active, .stale].contains($0.activityState) }
            .sorted { ($0.attributes.startedAt ?? .distantPast) > ($1.attributes.startedAt ?? .distantPast) }
    }
}
#endif
