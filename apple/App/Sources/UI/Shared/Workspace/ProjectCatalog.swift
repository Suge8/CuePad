import CueStore
import Foundation

nonisolated struct ProjectCatalog: Equatable, Sendable {
    var projects: [Project]
    var summaries: [UUID: ProjectSummary]
    var taskCounts: [UUID: TaskCounts]
    var directories: [UUID: String]
    var bindings: [DirectoryBinding]
    var workMac: MacAgents?

    var openTasks: [UUID: Int] { taskCounts.mapValues(\.open) }

    func project(_ id: UUID?) -> Project? {
        id.flatMap { id in projects.first { $0.id == id } }
    }

    static func read(from store: isolated CueStore) throws -> ProjectCatalog {
        let summaries = try store.projectSummaries()
        return ProjectCatalog(
            projects: try store.projects(),
            summaries: Dictionary(uniqueKeysWithValues: summaries.map { ($0.projectID, $0) }),
            taskCounts: try store.taskCounts(),
            directories: try store.projectDirectories(),
            bindings: try store.directoryBindings(),
            workMac: try store.workMac().map(store.macAgents(on:)))
    }
}
