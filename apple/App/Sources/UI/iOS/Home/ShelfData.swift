#if os(iOS)
import CueStore
import Foundation

/// 书架自己读的数据：项目、各项目的灵感数与任务数在窗口的项目目录（`ProjectCatalog`）里，这里只有目录里没有的。
/// 相等就不重画：编辑器自动保存写 cards 时，书架重读后多半还是同一份。
nonisolated struct ShelfData: Sendable, Equatable {
    /// 此刻有事的 Pi 会话（在线的，加上还有话发给它的已结束会话；带发给它的最近一条投送请求，`PiSessionQuery.current`）：
    /// 各项目的"此刻"一行在界面上再按本机的规则挑（`ProjectNow`）。
    var sessions: [PiSessionListItem]
    /// 各项目的进行中任务，最近开始的在前（`ProjectNow` 的一档）。
    var leading: [UUID: [ProjectNow.InProgress]]
    /// 正在推进的任务（顶层进行中的，Agent 要你处理的在前，规则 `TaskBoard.active`），书架最上面。
    var active: [TaskBoard.Row]
    /// 纸上列不下的进行中任务数：纸底写"还有 N 项"（点开是任务页）。
    var activeMore: Int
    var trashCount: Int

    static let activeLimit = 3

    /// 各项目的"此刻"（`ProjectNow`）：数据变化时算一次，卡与行只拿结果。"正在推进"已列出的任务不再写一遍。
    @MainActor func now(projects: [Project], shown: (PiSessionListItem) -> PiShown) -> [UUID: ProjectNow] {
        ProjectNow.byProject(projects, sessions: sessions, tasks: leading, listed: Set(active.map(\.id)), shown: shown)
    }

    static func read(from store: isolated CueStore) throws -> ShelfData {
        let active = try TaskBoard.active(limit: activeLimit, from: store)
        return ShelfData(
            sessions: try store.piSessionPage(.current).items, leading: try TaskBoard.leading(from: store),
            active: active.rows, activeMore: active.more, trashCount: try store.trashCount())
    }
}

/// 书架上的一个项目：项目与它的灵感数、未完成任务数（都来自项目目录）。
struct ShelfEntry: Sendable, Identifiable {
    var project: Project
    var cardCount: Int
    var openTasks: Int
    var id: UUID { project.id }
}

extension ProjectCatalog {
    var shelfEntries: [ShelfEntry] {
        projects.map { ShelfEntry(project: $0, cardCount: cardCounts[$0.id] ?? 0, openTasks: openTasks[$0.id] ?? 0) }
    }

    /// 没归项目的灵感数。
    var inboxCount: Int { cardCounts[nil] ?? 0 }

    /// 进任务页的入口上写的数：全部项目的顶层任务数，与任务页分组同一个数；一条任务都没有时为 nil，没有入口。
    var shelfTasks: TaskCounts? { allTasks == .zero ? nil : allTasks }
}
#endif
