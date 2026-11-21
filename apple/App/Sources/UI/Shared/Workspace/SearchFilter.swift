import CueStore
import Foundation

nonisolated struct PaletteQuery: Equatable {
    enum Period: Int, CaseIterable {
        case any = 0, week = 7, month = 30, quarter = 90

        var label: String {
            switch self {
            case .any: String(localized: "任意")
            case .week: String(localized: "近 7 天")
            case .month: String(localized: "近 30 天")
            case .quarter: String(localized: "近 90 天")
            }
        }
    }

    enum Kind: CaseIterable {
        case all, sessions, tasks, ideas

        var label: String {
            switch self {
            case .all: String(localized: "全部")
            case .sessions: String(localized: "会话")
            case .tasks: String(localized: "任务")
            case .ideas: String(localized: "灵感")
            }
        }
    }

    var text = "" { didSet { pages = 1; sessionPages = 1 } }
    var kind = Kind.all { didSet { pages = 1; sessionPages = 1 } }
    var project: UUID? { didSet { pages = 1 } }
    var withAttachments = false { didSet { pages = 1 } }
    var period: Period = .any { didSet { pages = 1 } }
    var pages = 1
    var sessionPages = 1

    var cards: PaletteQuery {
        var cards = self
        cards.sessionPages = 1
        return cards
    }

    static let pageSize = 30
    static let sessionPeek = 3

    var isFiltered: Bool { kind != .all || project != nil || withAttachments || period != .any }

    var isIdle: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !isFiltered }

    var listsSessions: Bool { !isIdle && (kind == .all || kind == .sessions) && !withAttachments && period == .any }
    var listsCards: Bool { !isIdle && kind != .sessions }

    var endedLimit: Int { kind == .sessions ? SessionListData.pageSize * sessionPages : Self.sessionPeek }

    func projectLabel(in projects: [Project]) -> String {
        project.flatMap { id in projects.first { $0.id == id }?.shownName } ?? String(localized: "全部")
    }

    func store(now: Date = .now) -> SearchQuery {
        var query = SearchQuery(text: text)
        if let project { query.projects = [project] }
        if withAttachments { query.hasAttachments = true }
        if kind == .tasks || kind == .ideas { query.isTask = kind == .tasks }
        if period != .any { query.modifiedIn = now.addingTimeInterval(-Double(period.rawValue) * 86_400)...now }
        return query
    }
}

nonisolated struct CardMatches: Sendable, Equatable {
    var groups: [CardGroup]
    var total: Int

    var entries: [CardEntry] { groups.flatMap(\.cards) }
    var shown: Int { groups.reduce(0) { $0 + $1.cards.count } }

    static func read(_ query: PaletteQuery, from store: isolated CueStore) throws -> CardMatches {
        guard query.listsCards else { return CardMatches(groups: [], total: 0) }
        let found = try store.search(query.store(), limit: PaletteQuery.pageSize * query.pages)
        return CardMatches(groups: CardGroup.byProject(found.cards), total: found.totalCards)
    }
}

nonisolated struct CardGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    var cards: [CardEntry]

    static func byProject(_ cards: [Card]) -> [CardGroup] {
        cards.runs { $0.projectID }.map { CardGroup(id: $0.id, cards: $0.items.map(CardEntry.init)) }
    }
}

nonisolated struct ProjectRun<Item: Sendable & Equatable>: Identifiable, Sendable, Equatable {
    let id: UUID
    var items: [Item]
}

nonisolated extension Array where Element: Sendable & Equatable {
    func runs(by project: (Element) -> UUID) -> [ProjectRun<Element>] {
        var runs: [ProjectRun<Element>] = []
        var index: [UUID: Int] = [:]
        for item in self {
            let id = project(item)
            if let at = index[id] {
                runs[at].items.append(item)
            } else {
                index[id] = runs.count
                runs.append(ProjectRun(id: id, items: [item]))
            }
        }
        return runs
    }
}
