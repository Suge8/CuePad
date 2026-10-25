import CueStore
import Foundation

/// 搜索的查询条件（界面侧，Mac ⌘K 与 iOS 搜索共用），换算成 Store 的 `SearchQuery`。
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

    // 换了条件就是另一组结果，从第一页看起（同 `AgentListModel.query`）：搜索词两种页数都回 1，筛选只管卡片；页数只由"显示更多"往上加
    var text = "" { didSet { pages = 1; sessionPages = 1 } }
    /// nil 不限。
    var project: UUID? { didSet { pages = 1 } }
    var withImages = false { didSet { pages = 1 } }
    var sent: SendCondition = .any { didSet { pages = 1 } }
    var period: Period = .any { didSet { pages = 1 } }
    var pages = 1
    /// Mac ⌘K 会话范围读到第几页（会话只按搜索词搜，筛选不管它）。
    var sessionPages = 1

    /// 卡片结果看的那部分：会话页数不算，会话范围点"显示更多"不重读卡片、卡片列表也不回顶。
    var cards: PaletteQuery {
        var cards = self
        cards.sessionPages = 1
        return cards
    }

    static let pageSize = 30

    var isFiltered: Bool { project != nil || withImages || sent != .any || period != .any }

    /// 项目筛选此刻的取值：选的项目名，没选是"全部"。
    func projectLabel(in projects: [Project]) -> String {
        project.flatMap { id in projects.first { $0.id == id }?.name } ?? String(localized: "全部")
    }

    /// "发给过谁"筛选此刻的取值。
    var sentLabel: String {
        switch sent {
        case .any: String(localized: "任意")
        case .never: String(localized: "没发过")
        case .sent(_, .some(let name)): name
        case .sent: String(localized: "发过")
        }
    }

    func store(now: Date = .now) -> SearchQuery {
        var query = SearchQuery(text: text)
        if let project { query.projects = [project] }
        if withImages { query.hasImages = true }
        query.sent = sent
        if period != .any { query.modifiedIn = now.addingTimeInterval(-Double(period.rawValue) * 86_400)...now }
        return query
    }
}

nonisolated extension SendTarget {
    /// "发给过谁"筛选菜单里的一项（`CueStore.sendTargets` 按种类与名字各出一条）。
    var filterID: String { "\(kind.rawValue)/\(name)" }
}

/// 卡片搜索读到的一页（Mac ⌘K 与手机搜索页同一份读法）：按项目分组的结果、总数，与"发给过谁"菜单里能选的目标。
/// 摘要在 Store 执行体上算好（`CardEntry`），渲染时不解析正文；项目名与图标从 `Workspace.catalog` 读，这里不另存一份。
nonisolated struct CardMatches: Sendable, Equatable {
    var groups: [CardGroup]
    var total: Int
    var targets: [SendTarget]

    /// 按分组的顺序排开，即界面上从上到下（方向键也照这个走）。
    var entries: [CardEntry] { groups.flatMap(\.cards) }
    var shown: Int { groups.reduce(0) { $0 + $1.cards.count } }

    static func read(_ query: PaletteQuery, from store: isolated CueStore) throws -> CardMatches {
        let found = try store.search(query.store(), limit: PaletteQuery.pageSize * query.pages)
        return CardMatches(groups: CardGroup.byProject(found.cards), total: found.totalCards, targets: try store.sendTargets())
    }
}

/// 搜索结果里一个项目的那几张（`id` 是项目）。
nonisolated struct CardGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    var cards: [CardEntry]

    /// 按项目分组，组按首次出现的顺序：结果最相关的在前，组也一样。
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
