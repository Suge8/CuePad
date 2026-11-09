import CueStore
import Foundation

nonisolated struct ProjectPageData: Sendable, Equatable {
    var project: Project?
    var cards: [Card]
    var lastSends: [UUID: LastSend]
    var tasks: TaskTree
    var done: [Card]
    var taskCounts: TaskCounts
    var subtasks: [UUID: TaskProgress]
    /// 由 `cards` 与 `lastSends` 推出，读取时算一次。
    var stamps: [CardStamp]
    /// 由 `lastSends` 推出，读取时算一次。
    var lastTarget: [UUID: String]

    static let doneLimit = 30

    static func read(_ project: UUID, from store: isolated CueStore) throws -> ProjectPageData {
        // 层级限制按本项目全部任务（含已完成）算
        let all = try store.tasks(in: project, .inProgress, .todo, .done)
        let cards = try store.cards(in: project), lastSends = try store.lastSends(in: project), info = try store.project(project)
        return ProjectPageData(
            project: info,
            cards: cards,
            lastSends: lastSends,
            tasks: TaskTree(all.filter { $0.status != .done }, all: all),
            done: try store.tasksDone(in: project, limit: doneLimit),
            taskCounts: try store.taskCounts(in: project),
            subtasks: try store.subtaskProgress(in: project),
            stamps: cards.map { CardStamp(id: $0.id, modifiedAt: $0.modifiedAt, lastSentAt: lastSends[$0.id]?.sentAt, isPinned: $0.isPinned) },
            lastTarget: lastSends.compactMapValues { send in
                send.target.shownName.map { $0 == info?.name ? SendCopy.sameProject : $0 }
            })
    }
}

nonisolated struct WallBoard: Equatable, Sendable {
    private(set) var arrangement: WallArrangement?
    private(set) var floated: Set<UUID> = []

    /// 用最新数据更新分区；返回是否是第一次排墙（调用方据此决定要不要动画）。
    @discardableResult
    mutating func refresh(with data: ProjectPageData, project: UUID, now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard let previous = arrangement else {
            arrangement = WallArrangement.arrange(data.stamps, project: project, now: now)
            return true
        }
        let next = previous.refreshed(with: data.stamps, project: project, now: now, calendar: calendar)
        floated = next.arrangedAt == previous.arrangedAt
            ? floated.union(Set(previous.older).intersection(next.wall + next.pinned))
            : []
        arrangement = next
        return false
    }
}

extension ProjectPageData {
    func olderGroups(_ arrangement: WallArrangement, now: Date = .now, calendar: Calendar = .current) -> [OlderGroup] {
        let byID = Dictionary(uniqueKeysWithValues: stamps.map { ($0.id, $0) })
        return OlderGroup.group(arrangement.older.compactMap { byID[$0] }, now: now, calendar: calendar)
    }
}
