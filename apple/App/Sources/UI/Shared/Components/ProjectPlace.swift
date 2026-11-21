import CueStore
import SwiftUI

struct ProjectPlace: Equatable {
    let text: Dotted
}

extension Workspace {
    func place(of project: Project) -> ProjectPlace? {
        guard let catalog else { return nil }
        #if os(macOS)
        if let directory = catalog.directories[project.id] {
            return ProjectPlace(text: Dotted(UserHome.shown(directory)))
        }
        return ProjectPlace(text: Dotted(pendingFolder(of: project), ProjectFolders.pending))
        #else
        return ProjectPlace(text: ProjectFolders.place(of: project, bindings: catalog.bindings, workMac: catalog.workMac))
        #endif
    }

    #if os(macOS)
    func pendingFolder(of project: Project) -> String {
        UserHome.shown(services.workspaces.directory(for: project.name).path(percentEncoded: false))
    }
    #endif
}
