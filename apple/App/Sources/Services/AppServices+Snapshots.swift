import CueStore
import Foundation
#if os(iOS)
import UIKit
import WidgetKit
#endif

/// 给小组件与分享扩展的快照：跟随资料库变化写进共享容器。扩展不打开资料库。
/// 只写内容真正变了的那份；小组件显示未分类与 Cue，只有这两份变了才刷新它们（刷新次数有系统预算）。
/// iPhone 的实时活动（`CueLiveActivity`）读同一条观察：后台被推送叫醒、拉到变化时也由它更新。
extension AppServices {
    /// 项目或卡片变化、此刻变了（Cue 的表情随它，`observeTimed`）时重读快照，直到任务取消。
    func startSnapshots() {
        follow(reporting: { .widgetDataUnavailable("\($0)") }) {
            for try await (content, moment) in self.observeTimed({ try $0.widgetContent() }) {
                try self.publish(WidgetSnapshots(content, at: moment))
                #if os(iOS)
                self.cueActivity.show(CueActivityState(content.cue, at: moment))
                #endif
            }
        }
        #if os(iOS)
        // 开启只能在前台：回到前台时再看一次要不要开，并从此刻重算过时时刻
        follow {
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) { self.cueActivity.resend() }
        }
        #endif
    }

    /// 立即按当前库内容更新快照（进入后台前）；实时活动按此刻重发一次，过时时刻从这时算。
    func writeSnapshots() async throws {
        let content = try await store.widgetContent()
        try publish(WidgetSnapshots(content, at: speech))
        #if os(iOS)
        await cueActivity.show(CueActivityState(content.cue, at: speech), resend: true).value
        #endif
    }

    private func publish(_ snapshots: WidgetSnapshots) throws {
        let old = publishedSnapshots
        try write(snapshots.projects, over: old?.projects)
        let shown = [try write(snapshots.unfiled, over: old?.unfiled), try write(snapshots.cue, over: old?.cue)]
        if shown.contains(true) { reloadWidgets() }
        publishedSnapshots = snapshots
    }

    private func reloadWidgets() {
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    /// 和上次写出的一样就不写；返回写了没有。
    @discardableResult
    private func write<S: SnapshotFile & Equatable>(_ snapshot: S, over old: S?) throws -> Bool {
        guard snapshot != old else { return false }
        try Snapshots.write(snapshot, to: location.snapshotsDirectory)
        return true
    }
}

/// 快照的全部内容：与上次写出的比较，决定写哪份、要不要刷新小组件。
nonisolated struct WidgetSnapshots: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var unfiled: UnfiledSnapshot
    var cue: CueSnapshot

    /// Cue 的表情随此刻（`CueSnapshot`），读库的那份不随。
    init(_ content: WidgetContent, at moment: Speech.Moment) {
        projects = content.projects
        unfiled = content.unfiled
        cue = CueSnapshot(digest: content.cue.digest, at: moment)
    }
}

/// 快照里从库里读的那份（`observeTimed` 订阅它）。
nonisolated struct WidgetContent: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var unfiled: UnfiledSnapshot
    /// Cue 的摘要与今天做完的（小组件只用摘要，实时活动都用）。
    var cue: CueActivityState.Reading
}

extension CueStore {
    fileprivate static let unfiledCardLimit = 5

    fileprivate func widgetContent() throws -> WidgetContent {
        let cards = try cards(in: nil)
        let latest = cards.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(Self.unfiledCardLimit)
        return WidgetContent(
            projects: ProjectsSnapshot(projects: try projects().map {
                ProjectsSnapshot.Project(id: $0.id, name: $0.name, color: $0.color, icon: $0.icon)
            }),
            unfiled: UnfiledSnapshot(
                cards: latest.map {
                    UnfiledSnapshot.Card(id: $0.id, title: $0.heading, modifiedAt: $0.modifiedAt)
                },
                total: cards.count),
            cue: try CueActivityState.Reading.read(from: self))
    }
}
