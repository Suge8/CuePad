import CueStore
import SwiftUI

/// 项目绑定的文件夹在哪：项目页栏头文件夹那颗钮的提示与它菜单的组头（`ProjectHeadTools`、`ProjectFolderItems`）只读这一份。
struct ProjectPlace: Equatable {
    let text: Dotted
}

extension Workspace {
    /// 读的是内存里的项目目录（`catalog`），不另订阅；目录还没读到为 nil。
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
    /// 接入面板说任务在哪做也读它。
    func pendingFolder(of project: Project) -> String {
        UserHome.shown(services.workspaces.directory(for: project.name).path(percentEncoded: false))
    }
    #endif
}
