import CueStore
import Foundation

/// 项目页一次读取的全部数据。
nonisolated struct ProjectPageData: Sendable {
    var project: Project?
    var cards: [Card]
    /// 卡片最近一次发送（时间与目标）；从未发送的卡不在里面。
    var lastSends: [UUID: LastSend]
    /// 本项目未完成的任务。
    var tasks: [CueTask]
    var directory: String?
    /// 资料库里有没有任何项目：空库首次打开时页面换成引导。
    var hasProjects = true

    /// 卡片最近一次发送的目标名。
    var lastTarget: [UUID: String] { lastSends.mapValues(\.target.name) }

    var goalCard: Card? {
        project?.goalCardID.flatMap { goal in cards.first { $0.id == goal } }
    }

    /// 目标卡在"目标与下一步"里，不再上墙或进更早。
    func stamps() -> [CardStamp] {
        cards.filter { $0.id != project?.goalCardID }.map { CardStamp(id: $0.id, modifiedAt: $0.modifiedAt, lastSentAt: lastSends[$0.id]?.sentAt, isPinned: $0.isFavorite) }
    }

    static func read(_ project: UUID?, from store: isolated CueStore) throws -> ProjectPageData {
        ProjectPageData(
            project: try project.flatMap { try store.project($0) },
            cards: try store.cards(in: project),
            lastSends: try store.lastSends(in: project),
            tasks: try store.tasks().filter { $0.projectID == project },
            directory: try project.flatMap { try store.directory(of: $0) },
            hasProjects: !(try store.projects().isEmpty))
    }
}

/// 项目页上墙的状态：当前分区，以及本次排墙之后从"更早"浮回墙上的卡（带 ↑ 标记）。Mac 与 iOS 项目页共用。
nonisolated struct WallBoard: Equatable, Sendable {
    private(set) var arrangement: WallArrangement?
    private(set) var floated: Set<UUID> = []

    /// 用最新数据更新分区；返回是否是第一次排墙（调用方据此决定要不要动画）。
    @discardableResult
    mutating func refresh(with data: ProjectPageData, project: UUID?, now: Date = .now, calendar: Calendar = .current) -> Bool {
        let stamps = data.stamps()
        guard let previous = arrangement else {
            arrangement = WallArrangement.arrange(stamps, project: project, now: now, calendar: calendar)
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

extension ProjectPageData {
    /// "更早"的分组。
    func olderGroups(_ arrangement: WallArrangement, now: Date = .now, calendar: Calendar = .current) -> [OlderGroup] {
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let stamps = arrangement.older.compactMap { byID[$0] }.map {
            CardStamp(id: $0.id, modifiedAt: $0.modifiedAt, lastSentAt: lastSends[$0.id]?.sentAt, isPinned: $0.isFavorite)
        }
        return OlderGroup.group(stamps, now: now, calendar: calendar)
    }
}
