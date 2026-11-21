import CueStore
import SwiftUI

struct ProjectActions: View {
    let project: Project
    var folders = true
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Group { items }.menuIcons()
    }

    @ViewBuilder private var items: some View {
        let id = project.id, pinned = !project.isPinned
        Button(project.isPinned ? "取消置顶" : "置顶", icon: project.isPinned ? .unpin : .pin) {
            workspace.perform { try await $0.updateProject(id) { $0.isPinned = pinned } }
        }
        Button("编辑名称与图标…", icon: .rename) { workspace.projectForm = .init(project: project) }
        if folders {
            Menu("文件夹", icon: .folder) { ProjectFolderItems(project: project) }
        } else {
            Button("看进展", icon: .task) { workspace.showProgress(of: id) }
        }
        if !project.isDefault {
            Divider()
            Button("移到回收站", icon: .trash, role: .destructive) {
                workspace.perform { try await $0.trashProject(id) }
            }
        }
    }
}

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

struct ProjectHeadTools: View {
    let project: Project
    var merged = false
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let rules = workspace.rules(of: project.id)
        Menu {
            ProjectFolderItems(project: project).labelStyle(.titleAndIcon)
            if merged, let rules { Button("规则", icon: .instruction) { workspace.openLibrary(rules) }.labelStyle(.titleAndIcon) }
        } label: { Label("文件夹", icon: .folder) }
            #if os(macOS)
            .menuStyle(.button).menuIndicator(.hidden).fixedSize()
            #endif
            .help(workspace.place(of: project)?.text.visible ?? String(localized: "文件夹"))
        if !merged, let rules {
            Button("规则", icon: .instruction) { workspace.openLibrary(rules) }
                .help("这个项目的 AGENTS.md")
        }
    }
}
