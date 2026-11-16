import CueStore
import SwiftUI

/// 项目的菜单，出现的每一处（会话条的项目行、项目总览页的行与格、手机项目页的"⋯"）都是这一份。
struct ProjectActions: View {
    let project: Project
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group { items }.menuIcons()
    }

    @ViewBuilder private var items: some View {
        let id = project.id, pinned = !project.isPinned
        Section { Button("看进展", icon: .task) { workspace.showProgress(of: id) } }
        Button(project.isPinned ? "取消置顶" : "置顶", icon: project.isPinned ? .unpin : .pin) {
            workspace.perform { try await $0.updateProject(id) { $0.isPinned = pinned } }
        }
        Button("编辑名称与图标…", icon: .rename) { workspace.projectForm = .init(project: project) }
        Section {
            #if os(macOS)
            if let directory = workspace.catalog?.directories[id] {
                Button("在访达中显示", icon: .folder) { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: directory, directoryHint: .isDirectory)]) }
            }
            #endif
            #if os(iOS)
            // 手机页顶那块玻璃里放不下"规则"（Mac 与 iPad 在介绍行末，`ProjectIntroLine`）：在这里
            if let rules = workspace.rules(of: id) {
                Button("规则", icon: .instruction) { workspace.openLibrary(rules) }
            }
            #endif
            Button("换文件夹…", icon: .folder) { workspace.chooseFolder(for: project) }
            let folders = ProjectFolders.menu(for: id, bindings: workspace.catalog?.bindings ?? [], host: workspace.localHost)
            ForEach(folders.unbinds, id: \.binding.id) { unbind in
                Button { workspace.unbindFolder(unbind.binding, of: project) } label: { Label { Text(unbind.title) } icon: { Image(.unbindFolder) } }
            }
        } header: {
            if let place = workspace.place(of: project) { Text(place.text) }
        }
        // 默认项目不能删（`CueStore.trashProject` 也拒绝）
        if !project.isDefault {
            Divider()
            Button("移到回收站", icon: .trash, role: .destructive) {
                workspace.perform { try await $0.trashProject(id) }
            }
        }
    }
}
