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
    /// 项目或卡片变化、此刻变了（Cue 的表情随它，`observeTimed`）时按 Cue 的现状（`CueFeed`，同一次读带着小组件另要的）改快照，直到任务取消。
    func startSnapshots() {
        follow(reporting: { .widgetDataUnavailable("\($0)") }) {
            for try await seen in self.cueUpdates() {
                guard let widget = seen.read.widget else { continue }
                try await self.present(widget, seen.read.digest, at: seen.moment, local: seen.local)
            }
        }
        #if os(iOS)
        // 开启只能在前台：回到前台时按库里此刻推一份，再看一次要不要开，过时时刻从此刻算
        if cueActivity != nil {
            follow {
                for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                    do {
                        try await self.writeSnapshots(resend: true)
                    } catch {
                        self.reportIssue(.widgetDataUnavailable("\(error)"))
                    }
                }
            }
        }
        #endif
    }

    #if os(iOS)
    /// 实时活动只能在前台开：启动到变成 active 之前（inactive）也算前台，库读完的第一份就能开，不等下一次变化。
    private static var inForeground: Bool { UIApplication.shared.applicationState != .background }
    #endif

    /// Cue 此刻：小组件、实时活动与 Cue 那一行（`CueWatch`）都经这里推（调试时可钉成一份样例，`-CuePadCueNow`）。
    /// 按推出的这一刻推：说的话的此刻（`SpeechClock`）只在时限到点、同步通断时走，库变了时它可能停在很久以前，
    /// 拿它算会把早过了 `doneWindow` 的"刚做完"当成新的、过时时刻也从那时算。
    static func cueNow(_ digest: CueDigest, at moment: Speech.Moment, local: CueNow.Local) -> CueNow {
        var moment = moment
        moment.now = .now
        return DebugHooks.preset.cueNow ?? CueNow(digest, at: moment, local: local)
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
        let read = try await CueFeed.Read.read(from: store, widget: true)
        try await present(read.widget!, read.digest, at: speech, local: cueLocal, resend: resend)
    }

    private func present(
        _ content: WidgetContent, _ digest: CueDigest, at moment: Speech.Moment, local: CueNow.Local, resend: Bool = false
    ) async throws {
        let now = Self.cueNow(digest, at: moment, local: local)
        #if os(iOS)
        await cueActivity?.show(CueActivityState(now: now, quotas: content.quotas), resend: resend, foreground: Self.inForeground)
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
    /// 实时活动那一份：Cue 此刻，加各家额度在它推出那一刻（`CueNow.at`）的读数（`QuotaMeter`）与本周快重置的提醒段（`QuotaReminder.isNear`）。
    nonisolated init(now: CueNow, quotas: [AccountQuota]) {
        let date = now.at
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

/// 小组件除 Cue 之外从库里读的那份（与 Cue 的摘要同一次读，`CueFeed.Read`）。
nonisolated struct WidgetContent: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var home: DefaultProjectSnapshot
    /// 各家订阅额度（只给实时活动）。
    var quotas: [AccountQuota]
}

extension CueStore {
    fileprivate static let widgetCardLimit = 5

    func widgetContent() throws -> WidgetContent {
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
            quotas: try accountQuotas())
    }
}
