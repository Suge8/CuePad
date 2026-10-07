#if os(macOS)
import AppKit
import CueStore
import SwiftUI

/// 项目右键菜单：共用的项目操作，加上 Mac 才有的绑定代码目录。
struct ProjectMenu: View {
    let project: Project
    let rename: () -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ProjectActions(project: project, edit: rename) {
            Button("绑定代码目录…", systemImage: "folder") { ProjectDirectory.choose(for: project.id, workspace: workspace) }
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

/// 新建或编辑项目：名称、一句话介绍、图标、颜色。
struct ProjectForm: View {
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var intro = ""
    @State private var icon = "folder"
    @State private var color = ProjectStylePicker.colors[0].hex

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project == nil ? "新建项目" : "编辑项目").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            TextField("一句话介绍（可不填）", text: $intro).textFieldStyle(.roundedBorder).onSubmit(save)
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
            intro = project.intro ?? ""
            icon = ProjectGlyph.symbol(project.icon)
            color = project.color
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let project = project, intro = intro, icon = icon, color = color
        workspace.attempt {
            let id = try await workspace.saveProject(project, name: name, intro: intro, icon: icon, color: color)
            if project == nil { workspace.show(.project(id)) }
        }
        dismiss()
    }
}
#endif
