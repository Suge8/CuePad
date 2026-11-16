import CueStore
import SwiftUI

/// 项目自己的操作（侧栏与项目列表里的右键、长按，项目页栏头点项目名）。`folders` 为假是项目页栏头那一份：不带文件夹那一组（另有一颗钮，`ProjectHeadTools`），多一项去看板只看这个项目——在别处人还没进这个项目。
struct ProjectActions: View {
    let project: Project
    var folders = true
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let id = project.id, pinned = !project.isPinned
        Button(project.isPinned ? "取消置顶" : "置顶", icon: project.isPinned ? .unpin : .pin) {
            workspace.perform { try await $0.updateProject(id) { $0.isPinned = pinned } }
        }
        Button("编辑名称与图标…", icon: .rename) { workspace.projectForm = .init(project: project) }
        if folders { ProjectFolderItems(project: project) } else { Button("看进展", icon: .task) { workspace.showProgress(of: id) } }
        // 默认项目不能删（`CueStore.trashProject` 也拒绝）
        if !project.isDefault {
            Divider()
            Button("移到回收站", icon: .trash, role: .destructive) {
                workspace.perform { try await $0.trashProject(id) }
            }
        }
    }
}

/// 绑定的文件夹那一组：组头写它在哪。
struct ProjectFolderItems: View {
    let project: Project
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let id = project.id
        Section {
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
        } header: {
            if let place = workspace.place(of: project) { Text(place.text) }
        }
    }
}

/// 项目页栏头里标题旁的两颗图标钮（三端同一份，长什么样由所在的那一排定）：文件夹——点开是它绑在哪、换与解除；规则——这个项目的 AGENTS.md，有才出。
struct ProjectHeadTools: View {
    let project: Project
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Menu { ProjectFolderItems(project: project).labelStyle(.titleAndIcon) } label: { Label("文件夹", icon: .folder) }
            #if os(macOS)
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            #endif
            .help(workspace.place(of: project)?.text.visible ?? String(localized: "文件夹"))
        if let rules = workspace.rules(of: project.id) {
            Button("规则", icon: .instruction) { workspace.openLibrary(rules) }
                .help("这个项目的 AGENTS.md")
        }
    }
}
