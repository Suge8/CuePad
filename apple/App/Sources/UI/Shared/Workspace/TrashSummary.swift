import CueStore
import Foundation

/// 回收站里的一行：删除的项目（连同其卡片）或单独删除的卡片。两端的回收站页列同一批行、做同一件事（恢复、永久删除）。
nonisolated struct TrashItem: Identifiable, Sendable {
    enum Kind: Sendable {
        case project(Project, cards: Int)
        case card(Card)
    }

    let kind: Kind

    var id: UUID {
        switch kind {
        case .project(let project, _): project.id
        case .card(let card): card.id
        }
    }

    var title: String {
        switch kind {
        case .project(let project, _): project.name
        case .card(let card): CardText(card.body).label
        }
    }

    /// 项目写带进来的卡片数，卡片写摘要。
    var detail: String {
        switch kind {
        case .project(_, let cards): CountCopy.text((cards, "条"))?.visible ?? ""
        case .card(let card): CardText(card.body).preview
        }
    }

    var deletedAt: Date? {
        switch kind {
        case .project(let project, _): project.deletedAt
        case .card(let card): card.deletedAt
        }
    }

    func restore(_ store: CueStore) async throws {
        switch kind {
        case .project(let project, _): try await store.restoreProject(project.id)
        case .card(let card): try await store.restoreCard(card.id)
        }
    }

    func purge(_ store: CueStore) async throws {
        switch kind {
        case .project(let project, _): try await store.purgeProject(project.id)
        case .card(let card): try await store.purgeCard(card.id)
        }
    }
}

/// 回收站此刻的内容（iOS 与 Mac 的回收站页同一份读取）。
nonisolated struct TrashSummary: Sendable {
    var projects: [TrashItem]
    var cards: [TrashItem]

    var isEmpty: Bool { projects.isEmpty && cards.isEmpty }
    var count: Int { projects.count + cards.count }

    static func read(from store: isolated CueStore) throws -> TrashSummary {
        TrashSummary(
            projects: try store.trashedProjects().map {
                TrashItem(kind: .project($0, cards: try store.search(SearchQuery(projects: [$0.id], inTrash: true), limit: 0).totalCards))
            },
            cards: try store.trashedCards().map { TrashItem(kind: .card($0)) })
    }
}

extension Workspace {
    func restore(_ item: TrashItem) { perform { try await item.restore($0) } }
    func purge(_ item: TrashItem) { perform { try await item.purge($0) } }
}
