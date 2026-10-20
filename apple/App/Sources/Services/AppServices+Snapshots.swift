import CueStore
import Foundation
#if os(iOS)
import WidgetKit
#endif

/// 给小组件与分享扩展的快照：跟随资料库变化写进共享容器。扩展不打开资料库。
/// 只写内容真正变了的那份；小组件显示默认项目与 Cue，只有这两份变了才刷新它们（刷新次数有系统预算）。
extension AppServices {
    /// 项目或卡片变化、此刻变了（Cue 的表情随它，`observeTimed`）时重读快照，直到任务取消。
    func startSnapshots() {
        follow(reporting: { .widgetDataUnavailable("\($0)") }) {
            for try await (content, moment) in self.observeTimed({ try $0.widgetContent() }) {
                try self.publish(WidgetSnapshots(content, at: moment))
            }
        }
    }

    /// 立即按当前库内容更新快照。
    func writeSnapshots() async throws {
        try publish(WidgetSnapshots(await store.widgetContent(), at: speech))
    }

    private func publish(_ snapshots: WidgetSnapshots) throws {
        let old = publishedSnapshots
        try write(snapshots.projects, over: old?.projects)
        let shown = [try write(snapshots.home, over: old?.home), try write(snapshots.cue, over: old?.cue)]
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
    var home: DefaultProjectSnapshot
    var cue: CueSnapshot

    /// Cue 的表情随此刻（`CueSnapshot`），读库的那份不随。
    init(_ content: WidgetContent, at moment: Speech.Moment) {
        projects = content.projects
        home = content.home
        cue = CueSnapshot(digest: content.cue, at: moment)
    }
}

/// 快照里从库里读的那份（`observeTimed` 订阅它）。
nonisolated struct WidgetContent: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var home: DefaultProjectSnapshot
    var cue: CueDigest
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
            cue: try CueDigest.read(from: self))
    }
}
