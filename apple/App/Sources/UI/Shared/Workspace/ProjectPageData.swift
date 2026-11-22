import CueStore
import Foundation

nonisolated struct ProjectPageData: Sendable, Equatable {
    var project: Project?
    var cards: [Card]
    var tasks: TaskTree
    var done: [Card]
    var taskCounts: TaskCounts
    var subtasks: [UUID: TaskProgress]
    var stamps: [CardStamp]
    var entries: [UUID: CardEntry]

    static let doneLimit = 30

    static func read(_ project: UUID, from store: isolated CueStore) throws -> ProjectPageData {
        let all = try store.tasks(in: project, .inProgress, .todo, .done)
        let cards = try store.cards(in: project)
        return ProjectPageData(
            project: try store.project(project),
            cards: cards,
            tasks: TaskTree(all.filter { $0.status != .done }, all: all),
            done: try store.tasksDone(in: project, limit: doneLimit),
            taskCounts: try store.taskCounts(in: project),
            subtasks: try store.subtaskProgress(in: project),
            stamps: cards.map { CardStamp(id: $0.id, modifiedAt: $0.modifiedAt, isPinned: $0.isPinned) },
            entries: Dictionary(uniqueKeysWithValues: cards.map { ($0.id, CardEntry($0)) }))
    }
}

nonisolated struct WallBoard: Equatable, Sendable {
    private(set) var arrangement: WallArrangement?
    private(set) var floated: Set<UUID> = []
    private(set) var older: [OlderGroup] = []

    @discardableResult
    mutating func refresh(with data: ProjectPageData, project: UUID, now: Date = .now, calendar: Calendar = .current) -> Bool {
        defer {
            let stamps = Dictionary(uniqueKeysWithValues: data.stamps.map { ($0.id, $0) })
            older = OlderGroup.group(arrangement?.older.compactMap { stamps[$0] } ?? [], now: now, calendar: calendar)
        }
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
