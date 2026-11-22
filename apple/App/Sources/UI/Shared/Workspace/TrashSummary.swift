import CueStore
import Foundation

nonisolated struct TrashItem: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let detail: String
    let deletedAt: Date?
    let project: Project?
    let card: Card?

    init(_ project: Project, cards: Int) {
        id = project.id
        title = project.shownName
        detail = CountCopy.items(cards) ?? ""
        deletedAt = project.deletedAt
        self.project = project
        card = nil
    }

    init(_ card: Card) {
        let text = CardText(card.body)
        id = card.id
        title = text.label
        detail = text.preview
        deletedAt = card.deletedAt
        project = nil
        self.card = card
    }

    func restore(_ store: CueStore) async throws {
        if project != nil { try await store.restoreProject(id) } else { try await store.restoreCard(id) }
    }

    func purge(_ store: CueStore) async throws {
        if project != nil { try await store.purgeProject(id) } else { try await store.purgeCard(id) }
    }

    func landing(_ store: CueStore) async throws -> Project? {
        if let project { return project }
        guard let id = try await store.card(id)?.projectID else { return nil }
        return try await store.project(id)
    }
}

nonisolated struct TrashSummary: Sendable, Equatable {
    var projects: [TrashItem]
    var cards: [TrashItem]

    var runs: [ProjectRun<TrashItem>] { cards.runs { $0.card?.projectID ?? Project.defaultID } }

    func project(of run: ProjectRun<TrashItem>, in catalog: ProjectCatalog?) -> Project? {
        catalog?.project(run.id) ?? projects.first { $0.id == run.id }?.project
    }

    var isEmpty: Bool { projects.isEmpty && cards.isEmpty }
    var count: Int { projects.count + cards.count }

    static func read(from store: isolated CueStore) throws -> TrashSummary {
        let counts = try store.trashedProjectCardCounts()
        return TrashSummary(
            projects: try store.trashedProjects().map { TrashItem($0, cards: counts[$0.id] ?? 0) },
            cards: try store.trashedCards().map(TrashItem.init))
    }
}

extension Workspace {
    func restore(_ item: TrashItem) {
        let store = services.store
        attempt {
            try await item.restore(store)
            let project = try await item.landing(store)
            self.say("已恢复到 \(project?.shownName ?? "")", link: project.map { .project($0.id) })
        }
    }
    func purge(_ item: TrashItem) { perform { try await item.purge($0) } }
}
