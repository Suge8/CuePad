import CueStore
import Foundation

nonisolated struct ProjectPageData: Sendable, Equatable {
    var project: Project?
    var cards: [Card]
    var tasks: TaskTree
    var done: [Card]
    var doneCount: Int
    var subtasks: [UUID: TaskProgress]
    var entries: [UUID: CardEntry]

    static let doneLimit = 30

    var stamps: [CardStamp] { cards.map { CardStamp(id: $0.id, modifiedAt: $0.modifiedAt, isPinned: $0.isPinned) } }

    static func read(_ project: UUID, from store: isolated CueStore) throws -> ProjectPageData {
        let tasks = try store.projectTasks(in: project, doneLimit: doneLimit)
        let cards = try store.cards(in: project)
        return ProjectPageData(
            project: try store.project(project),
            cards: cards,
            tasks: TaskTree(tasks.trees.filter { $0.completedAt == nil }, all: tasks.trees),
            done: tasks.done,
            doneCount: tasks.doneCount,
            subtasks: tasks.progress,
            entries: Dictionary(uniqueKeysWithValues: cards.map { ($0.id, CardEntry($0)) }))
    }
}

nonisolated struct WallBoard: Equatable, Sendable {
    private(set) var arrangement: WallArrangement?
    private(set) var floated: Set<UUID> = []
    private(set) var older: [OlderGroup] = []

    @discardableResult
    mutating func refresh(with data: ProjectPageData, project: UUID, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let stamps = data.stamps
        defer {
            let stamps = Dictionary(uniqueKeysWithValues: stamps.map { ($0.id, $0) })
            older = OlderGroup.group(arrangement?.older.compactMap { stamps[$0] } ?? [], now: now, calendar: calendar)
        }
        guard let previous = arrangement else {
            arrangement = WallArrangement.arrange(stamps, project: project, now: now)
            return true
        }
        let next = previous.refreshed(with: stamps, project: project, now: now, calendar: calendar)
        floated = next.arrangedAt == previous.arrangedAt
            ? floated.union(Set(previous.older).intersection(next.wall + next.pinned))
            : []
        arrangement = next
        return false
    }
}
