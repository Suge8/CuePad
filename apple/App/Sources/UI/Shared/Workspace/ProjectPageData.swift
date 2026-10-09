import CueStore
import Foundation

/// 项目页的内容（灵感、发送、任务）一次读取；项目的名称、图标、目录、计数在 `ProjectCatalog`。
nonisolated struct ProjectPageData: Sendable {
    var project: Project?
    /// 散放的灵感（不含任务与提示词）：卡片墙与"更早"。
    var cards: [Card]
    /// 卡片最近一次发送（时间与目标）；从未发送的卡不在里面。
    var lastSends: [UUID: LastSend]
    /// 本项目没完成的任务的层级，同级按手动顺序。
    var tasks: TaskTree
    /// 本项目顶层任务的完成数与总数（`CueStore.taskCounts`；没有任务时为 nil）。
    var taskProgress: TaskProgress?
    /// 任务的直接下级（子任务与挂着的灵感），完成圈与子任务进度由它推出。
    var children: [UUID: [ChildMark]]

    /// 卡片最近一次发给的 Agent 会话名（同名会话写"已发过"，已下线的去处不写，`SendTarget.shownName`）。
    var lastTarget: [UUID: String] {
        Dictionary(uniqueKeysWithValues: lastSends.compactMap { id, send in
            guard let name = send.target.shownName else { return nil }
            return (id, name == project?.name ? SendCopy.sameProject : name)
        })
    }

    func stamps() -> [CardStamp] {
        cards.map { CardStamp(id: $0.id, modifiedAt: $0.modifiedAt, lastSentAt: lastSends[$0.id]?.sentAt, isPinned: $0.isPinned) }
    }

    /// 没完成的任务的层级；层级限制按本项目全部任务（含已完成）算。
    private static func tree(_ project: UUID?, from store: isolated CueStore) throws -> TaskTree {
        let all = try store.tasks(.inProgress, .todo, .done).filter { $0.projectID == project }.flatMap(\.tasks)
        return TaskTree(all.filter { $0.status != .done }, all: all)
    }

    static func read(_ project: UUID?, from store: isolated CueStore) throws -> ProjectPageData {
        ProjectPageData(
            project: try project.flatMap { try store.project($0) },
            cards: try store.cards(in: project),
            lastSends: try store.lastSends(in: project),
            tasks: try Self.tree(project, from: store),
            taskProgress: try store.taskCounts()[project]?.progress,
            children: try store.childMarks())
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

extension ProjectPageData {
    /// "更早"的分组。
    func olderGroups(_ arrangement: WallArrangement, now: Date = .now, calendar: Calendar = .current) -> [OlderGroup] {
        let byID = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0) })
        let stamps = arrangement.older.compactMap { byID[$0] }.map {
            CardStamp(id: $0.id, modifiedAt: $0.modifiedAt, lastSentAt: lastSends[$0.id]?.sentAt, isPinned: $0.isPinned)
        }
        return OlderGroup.group(stamps, now: now, calendar: calendar)
    }
}
