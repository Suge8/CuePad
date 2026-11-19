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

    var text = "" { didSet { pages = 1; sessionPages = 1; sessionsExpanded = false } }
    var project: UUID? { didSet { pages = 1 } }
    var withAttachments = false { didSet { pages = 1 } }
    var period: Period = .any { didSet { pages = 1 } }
    var pages = 1
    /// 会话那一节先列 `sessionPeek` 个，点开才列全、分页。
    var sessionsExpanded = false
    var sessionPages = 1

    /// 卡片结果看的那部分：会话页数不算，会话范围点"显示更多"不重读卡片、卡片列表也不回顶。
    var cards: PaletteQuery {
        var cards = self
        cards.sessionPages = 1
        cards.sessionsExpanded = false
        return cards
    }

    static let pageSize = 30
    static let recent = 8

    var isFiltered: Bool { project != nil || withAttachments || period != .any }

    /// 没打字也没设条件：不把全库倒出来，只列手上的会话与最近改的 `recent` 条。
    var isIdle: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty && !isFiltered }

    /// 项目管得到会话；含附件、时间是灵感与任务才有的条件，设了它们会话那一节不列（列出来就是没筛过的）。
    var listsSessions: Bool { !withAttachments && period == .any }

    var sessionPeek: Int { isIdle ? 5 : 3 }

    /// 已结束的会话读几条：没展开时只为凑满 `sessionPeek`，闲着时不读（只列没结束的与置顶的）。
    var endedLimit: Int {
        if sessionsExpanded { return SessionListData.pageSize * sessionPages }
        return isIdle ? 0 : sessionPeek
    }

    func projectLabel(in projects: [Project]) -> String {
        project.flatMap { id in projects.first { $0.id == id }?.shownName } ?? String(localized: "全部")
    }

    func store(now: Date = .now) -> SearchQuery {
        var query = SearchQuery(text: text)
        if let project { query.projects = [project] }
        if withAttachments { query.hasAttachments = true }
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
        let idle = query.isIdle
        let found = try store.search(query.store(), limit: idle ? PaletteQuery.recent : PaletteQuery.pageSize * query.pages)
        return CardMatches(groups: CardGroup.byProject(found.cards), total: idle ? found.cards.count : found.totalCards)
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
