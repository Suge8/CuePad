import CueStore
import Foundation

struct SessionStart: Identifiable {
    let id = UUID()
    var project: UUID?

    func place(among places: [ProjectFolders.LaunchPlace]) -> ProjectFolders.LaunchPlace? {
        project.flatMap { project in places.first { $0.project.id == project } } ?? places.first
    }
}
