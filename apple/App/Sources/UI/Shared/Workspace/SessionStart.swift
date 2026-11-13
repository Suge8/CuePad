import CueStore
import Foundation

/// 新会话的输入框（`Workspace.newSession`）；进度存在 `sessionLaunching(.form)`。
struct SessionStart: Identifiable {
    let id = UUID()
    var project: UUID?

    func place(among places: [ProjectFolders.LaunchPlace]) -> ProjectFolders.LaunchPlace? {
        project.flatMap { project in places.first { $0.project.id == project } } ?? places.first
    }
}
