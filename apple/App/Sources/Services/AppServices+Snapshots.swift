import CueStore
import CueText
import Foundation
#if os(iOS)
import WidgetKit
#endif

/// 给小组件与分享扩展的快照：跟随资料库变化写进共享容器。扩展不打开资料库。
extension AppServices {
    /// 项目与收件箱变化时重写快照，直到任务取消。
    func startSnapshots() {
        let directory = location.snapshotsDirectory
        tasks.append(Task {
            do {
                for try await snapshot in store.observe([.projects], { try $0.projectsSnapshot() }) {
                    try Snapshots.write(snapshot, to: directory)
                    reloadWidgets()
                }
            } catch {
                reportIssue(.widgetDataUnavailable("\(error)"))
            }
        })
        tasks.append(Task {
            do {
                for try await snapshot in store.observe([.cards], { try $0.inboxSnapshot() }) {
                    try Snapshots.write(snapshot, to: directory)
                    reloadWidgets()
                }
            } catch {
                reportIssue(.widgetDataUnavailable("\(error)"))
            }
        })
    }

    /// 立即按当前库内容重写全部快照。
    func writeSnapshots() async throws {
        try Snapshots.write(await store.projectsSnapshot(), to: location.snapshotsDirectory)
        try Snapshots.write(await store.inboxSnapshot(), to: location.snapshotsDirectory)
        reloadWidgets()
    }

    private func reloadWidgets() {
        #if os(iOS)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

extension CueStore {
    fileprivate static let inboxCardLimit = 5

    fileprivate func projectsSnapshot() throws -> ProjectsSnapshot {
        ProjectsSnapshot(projects: try projects().map {
            ProjectsSnapshot.Project(id: $0.id, name: $0.name, color: $0.color, icon: $0.icon)
        })
    }

    fileprivate func inboxSnapshot() throws -> InboxSnapshot {
        let cards = try cards(in: nil)
        let latest = cards.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(Self.inboxCardLimit)
        return InboxSnapshot(
            cards: latest.map {
                InboxSnapshot.Card(id: $0.id, title: CueSummary($0.body).title, modifiedAt: $0.modifiedAt)
            },
            total: cards.count)
    }
}
