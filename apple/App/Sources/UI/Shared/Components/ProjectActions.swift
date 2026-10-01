import CueStore
import SwiftUI

/// 项目操作（Mac 右键、iOS 长按与项目页"更多"共用）：置顶、编辑名称与图标、移到回收站。
/// 编辑表单由调用方弹出（菜单收起后它所在的视图就没了）；平台专有的操作放进 `extra`，排在移到回收站之前。
struct ProjectActions<Extra: View>: View {
    let project: Project
    let edit: () -> Void
    @ViewBuilder var extra: Extra
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let id = project.id, pinned = !project.isPinned
        Button(project.isPinned ? "取消置顶" : "置顶", systemImage: project.isPinned ? "pin.slash" : "pin") {
            workspace.perform { try await $0.updateProject(id) { $0.isPinned = pinned } }
        }
        Button("编辑名称与图标…", systemImage: "pencil", action: edit)
        extra
        Divider()
        Button("移到回收站", systemImage: "trash", role: .destructive) {
            if workspace.currentProject == id { workspace.show(.inbox) }
            workspace.perform { try await $0.trashProject(id) }
        }
    }
}

extension ProjectActions where Extra == EmptyView {
    init(project: Project, edit: @escaping () -> Void) {
        self.init(project: project, edit: edit) { EmptyView() }
    }
}
