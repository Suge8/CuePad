import CueStore
import Foundation

/// 项目的文件夹绑定操作（iOS 与 Mac 共用的入口，规则见 `ProjectFolders`）。绑定只有一处写入：Mac 本机的 `CueStore.setDirectory`——
/// Mac 上经系统的选文件夹面板直接写；手机经投送请求（`PiBind`）让那台 Mac 解析并写。
extension Workspace {
    /// 这台 Mac 的标识：Mac 上新会话与绑定只管本机；手机没有。
    var localHost: String? {
        #if os(macOS)
        services.hostID
        #else
        nil
        #endif
    }

    /// 给项目绑定或更换文件夹：Mac 弹系统的选文件夹面板，手机弹候选（`folderPicker`）。
    func chooseFolder(for project: Project) {
        #if os(macOS)
        ProjectDirectory.choose(for: project.id, workspace: self)
        #else
        folderPicker = project
        #endif
    }

    /// 解除某台 Mac 上项目的绑定：就是本机的直接写，别的 Mac 上的请那台 Mac 做。
    func unbindFolder(_ binding: DirectoryBinding, of project: Project) {
        let id = project.id, name = project.name
        attempt {
            if binding.hostID == self.localHost {
                try await self.services.store.setDirectory(nil, for: id)
            } else {
                try await self.requestFolder(PiBind(project: id, folder: nil), title: name, on: binding.hostID)
            }
        }
    }

    /// 请 `host` 那台 Mac 绑定（或解除）并等它的结果：没成功时抛出那台 Mac 写回的原因。
    func requestFolder(_ bind: PiBind, title: String, on host: String) async throws {
        let request = try await services.requestBind(bind, title: title, on: host)
        if let failure = try await services.outcome(of: request.id).failure { throw SendError.notDelivered(failure) }
    }
}
