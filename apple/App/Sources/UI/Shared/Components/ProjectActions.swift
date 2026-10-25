import CueStore
import SwiftUI

/// 项目操作（Mac 右键、iOS 长按与项目页"更多"共用）：置顶、编辑名称与图标、文件夹一组（组头写文件夹在哪，下面更换与解除绑定，规则 `ProjectFolders.menu`）、移到回收站。
/// 编辑表单由调用方弹出（菜单收起后它所在的视图就没了）；平台专有的操作放进 `extra`，排在移到回收站之前。
struct ProjectActions<Extra: View>: View {
    let project: Project
    let edit: () -> Void
    @ViewBuilder var extra: Extra
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let id = project.id, pinned = !project.isPinned
        Button(project.isPinned ? "取消置顶" : "置顶", icon: project.isPinned ? .unpin : .pin) {
            workspace.perform { try await $0.updateProject(id) { $0.isPinned = pinned } }
        }
        Button("编辑名称与图标…", icon: .rename, action: edit)
        Section(folderPlace) {
            #if os(macOS)
            if let directory = workspace.catalog?.directories[id] {
                Button("在访达中显示", icon: .folder) { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory, directoryHint: .isDirectory)]) }
            }
            #endif
            Button("换文件夹…", icon: .folder) { workspace.chooseFolder(for: project) }
            let folders = ProjectFolders.menu(for: id, bindings: workspace.catalog?.bindings ?? [], host: workspace.localHost)
            ForEach(folders.unbinds, id: \.binding.id) { unbind in
                Button { workspace.unbindFolder(unbind.binding, of: project) } label: { Label { Text(unbind.title) } icon: { Image(.unbindFolder) } }
            }
        }
        extra
        // 默认项目不能删（`CueStore.trashProject` 也拒绝）
        if !project.isDefault {
            Divider()
            Button("移到回收站", icon: .trash, role: .destructive) {
                #if os(macOS)
                // 正看着它：换到默认项目（iOS 上项目页自己发现项目不在了就退回，见 `ProjectScreen`）
                if workspace.currentProject == id { workspace.show(.project(Project.defaultID)) }
                #endif
                workspace.perform { try await $0.trashProject(id) }
            }
        }
    }

    /// 文件夹那一组的组头：Mac 写本机的路径（短写，`Workspaces.shown`；没绑时写开工时会建好的工作区），手机写在哪台 Mac 上（`ProjectFolders.places`）。
    private var folderPlace: String {
        #if os(macOS)
        if let directory = workspace.catalog?.directories[project.id] { return Workspaces.shown(directory) }
        let workspaces = workspace.services.workspaces
        return String(localized: "\(Workspaces.shown(workspaces.directory(for: project.name).path(percentEncoded: false)))（开工时建好）")
        #else
        guard let catalog = workspace.catalog else { return "" }
        return ProjectFolders.places(of: project, bindings: catalog.bindings, workMac: catalog.workMac).joined(separator: "；")
        #endif
    }
}

extension ProjectActions where Extra == EmptyView {
    init(project: Project, edit: @escaping () -> Void) {
        self.init(project: project, edit: edit) { EmptyView() }
    }
}
