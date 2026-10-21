import CueStore
import Foundation

/// 搜索的查询条件（界面侧，Mac ⌘K 与 iOS 搜索共用），换算成 Store 的 `SearchQuery`。
nonisolated struct PaletteQuery: Equatable {
    enum Period: Int, CaseIterable {
        case any = 0, week = 7, month = 30, quarter = 90

        var label: String {
            switch self {
            case .any: "任意"
            case .week: "近 7 天"
            case .month: "近 30 天"
            case .quarter: "近 90 天"
            }
        }
    }

    var text = ""
    /// nil 不限。
    var project: UUID?
    var withImages = false
    var sent: SendCondition = .any
    var period: Period = .any
    var pages = 1

    static let pageSize = 30

    var isFiltered: Bool { project != nil || withImages || sent != .any || period != .any }

    /// 项目筛选此刻的取值：选的项目名，没选是"全部"。
    func projectLabel(in projects: [Project]) -> String {
        project.flatMap { id in projects.first { $0.id == id }?.name } ?? "全部"
    }

    /// "发给过谁"筛选此刻的取值。
    var sentLabel: String {
        switch sent {
        case .any: "任意"
        case .never: "没发过"
        case .sent(_, .some(let name)): name
        case .sent: "发过"
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

/// 搜索结果里一个项目的那几张（`id` 是项目）。
nonisolated struct CardGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    var cards: [Card]

    /// 按项目分组，组按首次出现的顺序：结果最相关的在前，组也一样。
    static func byProject(_ cards: [Card]) -> [CardGroup] {
        var groups: [CardGroup] = []
        var index: [UUID: Int] = [:]
        for card in cards {
            if let at = index[card.projectID] {
                groups[at].cards.append(card)
            } else {
                index[card.projectID] = groups.count
                groups.append(CardGroup(id: card.projectID, cards: [card]))
            }
        }
        return groups
    }
}
