#if os(iOS)
import ActivityKit
import CueStore
import Foundation
import OSLog

/// iPhone 上只开一个实时活动。有真实同步时请求推送令牌，内容与结束由 Mac 经 APNs 独占写入；
/// 本地库可能落后于系统刚收到的推送，不能在回前台、后台拉取或回答后拿本地快照覆盖它。
/// 隔离演示没有远程发布者，才由本地更新与结束。系统只允许前台开启，八小时结束后也要回到前台再开。
/// 退出账号、换号或清除所属资料时手机仍负责撤销活动；暂时离线不撤销。重开前必须按已对账的当前库取内容。
/// 令牌的初值、轮换与结束在同一服务维护（`CueLiveActivity+Destination`），不等待窗口或下一次前台激活。
final class CueLiveActivity {
    static let log = Logger(subsystem: AppIdentity.id, category: "live-activity")
    let store: CueStore
    let sync: (any SyncControlling)?
    let device: String?
    private let remoteState: () throws -> CueActivityState?
    private var restoration: Task<Void, Never>?
    private(set) var revision = UUID()
    var observers: [String: [Task<Void, Never>]] = [:]
    var destinationWork: Task<Void, Never>?

    init(store: CueStore, sync: (any SyncControlling)?, device: String?, remoteState: @escaping () throws -> CueActivityState?) {
        self.store = store
        self.sync = sync
        self.device = device
        self.remoteState = remoteState
        restoration = Task { [revision] in await restore(revision) }
    }

    isolated deinit {
        restoration?.cancel()
        for tasks in observers.values { for task in tasks { task.cancel() } }
    }

    private func restore(_ revision: UUID) async {
        let activities = Self.running
        for extra in activities.dropFirst() {
            guard revision == self.revision else { return }
            await extra.end(nil, dismissalPolicy: .immediate, timestamp: .now)
            await removeDestination(activityID: extra.id)
        }
        guard revision == self.revision else { return }
        if activities.first?.attributes.remoteUpdates != true { await removeDestination(activityID: nil) }
    }

    /// 当场使旧请求失效；先结束系统活动，再等已入途的令牌写入收尾，最后撤销地址。
    /// show 等同一个屏障，所以旧任务不能在新活动登记后补写旧令牌，也不需要在 Store 另存生命周期。
    @discardableResult
    func invalidate() -> Task<Void, Never> {
        revision = UUID()
        let previous = restoration
        for tasks in observers.values { for task in tasks { task.cancel() } }
        observers.removeAll()
        let ids = Set(Self.running.map(\.id))
        let ending = Task {
            for activity in Self.running where ids.contains(activity.id) { await activity.end(nil, dismissalPolicy: .immediate, timestamp: .now) }
            await previous?.value
            await removeDestination(activityID: nil)
        }
        restoration = ending
        return ending
    }

    /// foreground 只决定能否开启；远程活动的初始内容必须在等待后从当前所属库重新取。
    func show(_ state: CueActivityState, resend: Bool, foreground: Bool) async {
        let revision = revision
        await restoration?.value
        guard revision == self.revision, !Task.isCancelled else { return }
        do {
            try await present(state, resend: resend, foreground: foreground, revision: revision)
        } catch {
            Self.log.error("实时活动没能开启：\(String(describing: error), privacy: .public)")
        }
    }

    private func present(_ local: CueActivityState, resend: Bool, foreground: Bool, revision: UUID) async throws {
        var running = Self.running.first
        // 远程活动即使暂时离线，也不能由本地库接管内容。重启进程后先确认资料所属，再登记令牌。
        if let running, running.attributes.remoteUpdates == true {
            if observers[running.id] == nil, try remoteState() != nil { observe(running) }
            return
        }
        if sync != nil, let old = running {
            guard foreground, try remoteState() != nil else { return }
            await old.end(nil, dismissalPolicy: .immediate, timestamp: .now)
            guard revision == self.revision, !Task.isCancelled else { return }
            running = Self.running.first
            if running?.attributes.remoteUpdates == true { return }
        }
        let state: CueActivityState
        if sync != nil {
            guard let current = try remoteState() else { return }
            state = current
        } else {
            state = local
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
        let activity = try Activity.request(
            attributes: CueActivityAttributes(remoteUpdates: sync != nil), content: content, pushType: sync == nil ? nil : .token)
        if sync != nil { observe(activity) }
    }

    nonisolated static var running: [Activity<CueActivityAttributes>] {
        Activity<CueActivityAttributes>.activities
            .filter { [.active, .stale].contains($0.activityState) }
            .sorted { ($0.attributes.startedAt ?? .distantPast) > ($1.attributes.startedAt ?? .distantPast) }
    }
}
#endif
