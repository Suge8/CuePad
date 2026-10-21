import CueStore
import Foundation
#if os(iOS)
import UIKit
import WidgetKit
#endif

/// 给小组件与分享扩展的快照：跟随资料库变化写进共享容器。扩展不打开资料库。
/// 只写内容真正变了的那份；小组件显示默认项目与 Cue，只有这两份变了才刷新它们（刷新次数有系统预算）。
/// iPhone 的实时活动（`CueLiveActivity`）与小组件读同一份 Cue 此刻，每次都先改岛：后台被推送叫醒时剩的时间不多。
extension AppServices {
    /// 项目或卡片变化、此刻变了（Cue 的表情随它，`observeTimed`）时重读快照，直到任务取消。
    func startSnapshots() {
        follow(reporting: { .widgetDataUnavailable("\($0)") }) {
            for try await (content, moment, local) in self.observeCue({ try $0.widgetContent() }) {
                try await self.present(content, at: moment, local: local)
            }
        }
        #if os(iOS)
        // 开启只能在前台：回到前台时再看一次要不要开，并从此刻重算过时时刻
        if let activity = cueActivity {
            follow {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    await activity.resend(foreground: true)
                }
            }
        }
        #endif
    }

    #if os(iOS)
    private static var isActive: Bool { UIApplication.shared.applicationState == .active }
    #endif

    /// Cue 此刻：小组件、实时活动与 Cue 那一行（`CueWatch`）都经这里推（调试时可钉成一份样例，`-CuePadCueNow`）。
    static func cueNow(_ digest: CueDigest, at moment: Speech.Moment, local: CueNow.Local) -> CueNow {
        DebugHooks.preset.cueNow ?? CueNow(digest, at: moment, local: local)
    }

    /// Cue 此刻要的本机事实：还没和 iCloud 对过时为什么等（与启用入口同一处判断 `CueGate`），这台 Mac 是哪台。
    var cueLocal: CueNow.Local {
        #if os(macOS)
        let here: String? = hostID
        #else
        let here: String? = nil
        #endif
        return CueNow.Local(waiting: CueGate.of(self, running: nil, name: nil).waitingReason, here: here)
    }

    /// 立即按当前库内容更新，不等快照那条异步的观察：进入后台前（`resend`：岛按此刻重发一次，过时时刻从这时算）、
    /// 推送叫醒拉完之后（回调一返回系统就可能挂起 App，`IOSAppDelegate`）。
    func writeSnapshots(resend: Bool = false) async throws {
        try await present(try await store.widgetContent(), at: speech, local: cueLocal, resend: resend)
    }

    private func present(_ content: WidgetContent, at moment: Speech.Moment, local: CueNow.Local, resend: Bool = false) async throws {
        let now = Self.cueNow(content.cue, at: moment, local: local)
        #if os(iOS)
        await cueActivity?.show(CueActivityState(now: now, quotas: content.quotas, at: moment.now), resend: resend, foreground: Self.isActive)
        #endif
        try publish(WidgetSnapshots(content, now: now))
    }

    private func publish(_ snapshots: WidgetSnapshots) throws {
        let old = publishedSnapshots
        try write(snapshots.projects, over: old?.projects)
        let shown = [try write(snapshots.home, over: old?.home), try write(snapshots.cue, over: old?.cue, same: { $0.same(as: $1) })]
        if shown.contains(true) { reloadWidgets() }
        publishedSnapshots = snapshots
    }

    private func reloadWidgets() {
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// 和上次写出的一样（`same`，默认相等）就不写；返回写了没有。
    @discardableResult
    private func write<S: SnapshotFile & Equatable>(_ snapshot: S, over old: S?, same: (S, S) -> Bool = (==)) throws -> Bool {
        if let old, same(snapshot, old) { return false }
        try Snapshots.write(snapshot, to: location.snapshotsDirectory)
        return true
    }
}

/// 快照的全部内容：与上次写出的比较，决定写哪份、要不要刷新小组件。
nonisolated struct WidgetSnapshots: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var home: DefaultProjectSnapshot
    var cue: CueNow

    /// Cue 此刻随此刻推（在不在、话在不在路上、表情，`AppServices.cueNow`），读库的那份不随。
    init(_ content: WidgetContent, now: CueNow) {
        projects = content.projects
        home = content.home
        cue = now
    }

    /// 只比内容（Cue 此刻推出的时刻不算）：内容一样就不重写、不刷新小组件。
    static func == (a: Self, b: Self) -> Bool { a.projects == b.projects && a.home == b.home && a.cue.same(as: b.cue) }
}

extension CueActivityState {
    /// 实时活动那一份：Cue 此刻，加各家额度此刻（`date`）的读数（`QuotaMeter`）与本周快重置的提醒段（`QuotaReminder.isNear`）。
    nonisolated init(now: CueNow, quotas: [AccountQuota], at date: Date) {
        self.now = now
        self.quotas = quotas.compactMap { quota in
            let meter = QuotaMeter(quota, at: date)
            let week = QuotaReminder.window(of: quota)
            let windows = meter.windows.map { window in
                Quota.Window(
                    name: window.name, left: window.left, level: window.level, resetsAt: window.resetsAt,
                    near: week.map { window.id == $0.id && QuotaReminder.isNear($0, at: date) } ?? false)
            }
            return windows.isEmpty ? nil : Quota(account: meter.account, windows: windows)
        }
    }
}

/// 快照里从库里读的那份（`observeTimed` 订阅它）。
nonisolated struct WidgetContent: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var home: DefaultProjectSnapshot
    var cue: CueDigest
    /// 各家订阅额度（只给实时活动）。
    var quotas: [AccountQuota]
}

extension CueStore {
    fileprivate static let widgetCardLimit = 5

    fileprivate func widgetContent() throws -> WidgetContent {
        let cards = try cards(in: Project.defaultID)
        let latest = cards.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(Self.widgetCardLimit)
        return WidgetContent(
            projects: ProjectsSnapshot(projects: try projects().map {
                ProjectsSnapshot.Project(id: $0.id, name: $0.name, color: $0.color, icon: $0.icon)
            }),
            home: DefaultProjectSnapshot(
                name: try project(Project.defaultID)?.name ?? "",
                cards: latest.map {
                    DefaultProjectSnapshot.Card(id: $0.id, title: $0.heading, modifiedAt: $0.modifiedAt)
                },
                total: cards.count),
            cue: try CueDigest.read(from: self),
            quotas: try accountQuotas())
    }
}
