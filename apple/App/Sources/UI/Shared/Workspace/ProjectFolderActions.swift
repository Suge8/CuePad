import CueStore
import Foundation

/// 绑定只有一处写入：Mac 本机的 `CueStore.setDirectory`；手机经投送请求（`BindRequest`）让那台 Mac 解析并写。
extension Workspace {
    var localHost: String? {
        #if os(macOS)
        services.hostID
        #else
        nil
        #endif
    }

    /// 新会话能开在哪：Mac 只在本机开，手机看各台的绑定、没绑的交给建工作区的那台。
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

    /// 请 `host` 那台 Mac 绑定（或解除）并等它的结果：没成功时抛出那台 Mac 写回的原因。
    func requestFolder(_ bind: BindRequest, title: String, on host: String) async throws {
        let request = try await services.requestBind(bind, title: title, on: host)
        if let failure = try await services.store.outcome(of: request).failure { throw SendError.notDelivered(failure) }
    }
}
