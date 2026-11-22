import CueStore
import Foundation

extension Workspace {
    var localHost: String? {
        #if os(macOS)
        services.hostID
        #else
        nil
        #endif
    }

    var launchPlaces: [ProjectFolders.LaunchPlace] {
        ProjectFolders.launchPlaces(
            projects: catalog?.projects ?? [], bindings: catalog?.bindings ?? [], host: localHost, workMac: catalog?.workMac?.hostID)
    }

    func chooseFolder(for project: Project) {
        #if os(macOS)
        ProjectDirectory.choose(for: project.id, workspace: self)
        #else
        folderPicker = project
        #endif
    }

    func unbindFolder(_ binding: DirectoryBinding, of project: Project) {
        let id = project.id, name = project.shownName
        attempt {
            if binding.hostID == self.localHost {
                try await self.services.store.setDirectory(nil, for: id)
            } else {
                try await self.requestFolder(BindRequest(project: id, folder: nil), title: name, on: binding.hostID)
            }
        }
    }

    func requestFolder(_ bind: BindRequest, title: String, on host: String) async throws {
        let request = try await services.requestBind(bind, title: title, on: host)
        if let failure = try await services.store.outcome(of: request).failure { throw SendError.notDelivered(failure) }
    }
}
