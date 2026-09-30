#if os(macOS)
import AppKit
import CueStore
import SwiftUI

/// 项目右键菜单：编辑、置顶、绑定代码目录、移到回收站。
struct ProjectMenu: View {
    let project: Project
    let rename: () -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("编辑名称与图标…", action: rename)
        Button(project.isPinned ? "取消置顶" : "置顶") {
            let id = project.id, pinned = !project.isPinned
            workspace.perform { try await $0.updateProject(id) { $0.isPinned = pinned } }
        }
        Button("绑定代码目录…") { ProjectDirectory.choose(for: project.id, workspace: workspace) }
        Divider()
        Button("移到回收站", role: .destructive) {
            let id = project.id
            if workspace.currentProject == id { workspace.show(.inbox) }
            workspace.perform { try await $0.trashProject(id) }
        }
    }
}

enum ProjectDirectory {
    /// 选择目录后绑定；Pi 会话按这个目录归入项目。
    static func choose(for project: UUID, workspace: Workspace) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "绑定"
        panel.message = "选择这个项目的代码目录，在其中运行的 Pi 会话会归到这个项目"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        workspace.perform { try await $0.setDirectory(path, for: project) }
    }
}

/// 新建或编辑项目：名称、图标、颜色。
struct ProjectForm: View {
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "folder"
    @State private var color = ProjectStylePicker.colors[0].hex

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project == nil ? "新建项目" : "编辑项目").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            ProjectStylePicker(icon: $icon, color: $color, cell: 30)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(project == nil ? "创建" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear {
            guard let project else { return }
            name = project.name
            icon = ProjectGlyph.symbol(project.icon)
            color = project.color
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let project = project, icon = icon, color = color
        workspace.attempt {
            let id = try await workspace.saveProject(project, name: name, icon: icon, color: color)
            if project == nil { workspace.show(.project(id)) }
        }
        dismiss()
    }
}
#endif
