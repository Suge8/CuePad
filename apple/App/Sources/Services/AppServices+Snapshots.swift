import CueStore
import Foundation
#if os(iOS)
import WidgetKit
#endif

/// 给小组件与分享扩展的快照：跟随资料库变化写进共享容器。扩展不打开资料库。
/// 只写内容真正变了的那份；小组件显示未分类与 Cue，只有这两份变了才刷新它们（刷新次数有系统预算）。
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
        let directory = location.snapshotsDirectory
        if snapshots.projects != publishedSnapshots?.projects { try Snapshots.write(snapshots.projects, to: directory) }
        if snapshots.unfiled != publishedSnapshots?.unfiled {
            try Snapshots.write(snapshots.unfiled, to: directory)
            reloadWidgets()
        }
        if snapshots.cue != publishedSnapshots?.cue {
            try Snapshots.write(snapshots.cue, to: directory)
            reloadWidgets()
        }
        publishedSnapshots = snapshots
    }

    private func reloadWidgets() {
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
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
        cue = CueSnapshot(digest: content.cue, at: moment)
    }
}

/// 快照里从库里读的那份（`observeTimed` 订阅它）。
nonisolated struct WidgetContent: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var unfiled: UnfiledSnapshot
    var cue: CueDigest
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
            cue: try CueDigest.read(from: self))
    }
}
