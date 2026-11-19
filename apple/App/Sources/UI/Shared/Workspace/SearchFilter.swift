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
    /// 只看会话（`kind == .sessions`）时才分页；别的时候会话那一节只列头 `sessionPeek` 个。
    var sessionPages = 1

    /// 卡片结果看的那部分：会话页数不算，会话范围点"显示更多"不重读卡片、卡片列表也不回顶。
    var cards: PaletteQuery {
        var cards = self
        cards.sessionPages = 1
        return cards
    }

    static let pageSize = 30
    static let sessionPeek = 3

    var isFiltered: Bool { kind != .all || project != nil || withAttachments || period != .any }

    /// 没打字也没设条件：什么都不列，只给几类建议（`SearchSuggestions`），不把全库倒出来。
    var isIdle: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !isFiltered }

    /// 项目管得到会话；含附件、时间是灵感与任务才有的条件，设了它们会话那一节不列（列出来就是没筛过的）。
    var listsSessions: Bool { !isIdle && (kind == .all || kind == .sessions) && !withAttachments && period == .any }
    var listsCards: Bool { !isIdle && kind != .sessions }

    /// 已结束的会话读几条：只看会话时分页，别的时候只为凑满 `sessionPeek`。
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

/// 摘要在 Store 执行体上算好（`CardEntry`），渲染时不解析正文；项目名与图标从 `Workspace.catalog` 读，这里不另存一份。
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
        var groups: [CardGroup] = []
        var index: [UUID: Int] = [:]
        for card in cards {
            if let at = index[card.projectID] {
                groups[at].cards.append(CardEntry(card))
            } else {
                index[card.projectID] = groups.count
                groups.append(CardGroup(id: card.projectID, cards: [CardEntry(card)]))
            }
        }
        return groups
    }
}
