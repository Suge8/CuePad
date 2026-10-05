import CueStore
import Foundation

/// 本窗口的项目目录：有效项目（`store.projects()` 的顺序，界面不再另排；侧栏、书架、⌘1–9 与所有项目选择器都按它）、各项目与未归档的卡片数、本机绑定的代码目录。
/// 由 `Workspace.observeCatalog` 订阅；项目的名称、图标、计数、目录在界面里都从这里同步取，
/// 进入项目页、打开菜单时第一帧就是真实值，不先显示默认值再替换。
nonisolated struct ProjectCatalog: Equatable, Sendable {
    var projects: [Project]
    /// 键为 nil 的是未归档。
    var cardCounts: [UUID?: Int]
    var directories: [UUID: String]

    static let tables: Set<StoreTable> = [.projects, .cards, .projectDirectories]

    func project(_ id: UUID?) -> Project? {
        id.flatMap { id in projects.first { $0.id == id } }
    }

    static func read(from store: isolated CueStore) throws -> ProjectCatalog {
        let summaries = try store.projectSummaries()
        return ProjectCatalog(
            projects: try store.projects(),
            cardCounts: Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0.cardCount) }),
            directories: try store.projectDirectories())
    }
}
