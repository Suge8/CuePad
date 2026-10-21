#if os(macOS)
import CueStore
import SwiftUI

enum ProjectDirectory {
    /// 弹系统的选文件夹面板，返回选中的路径（取消为 nil）。
    static func pick() async -> String? {
        await FilePicker.folder(message: "选择这个项目的文件夹，在其中运行的 Agent 会话会归到这个项目，新会话也开在这里")?
            .path(percentEncoded: false)
    }

    /// 选择文件夹后绑定；Pi 会话按这个目录归入项目。
    static func choose(for project: UUID, workspace: Workspace) {
        workspace.attempt {
            guard let path = await pick() else { return }
            try await workspace.services.store.setDirectory(path, for: project)
        }
    }
}

/// 新建或编辑项目：名称、一句话介绍、图标、颜色；新建时还可以选文件夹（不选的第一次开工时建工作区，之后在项目菜单里换）。
struct ProjectForm: View {
    /// 新建（`project` 为 nil）或编辑哪个项目（`Workspace.projectForm`）。
    struct Request: Identifiable {
        let id = UUID()
        var project: Project?
    }

    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @State private var name = ""
    @State private var intro = ""
    @State private var icon = ProjectIcon.folder
    @State private var color = Palette.projectColors[0].stored
    /// 新建时选的文件夹（完整路径）；编辑项目不在这里改绑定，项目菜单里改。
    @State private var folder: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(project == nil ? "新建项目" : "编辑项目").font(Typography.bodyStrong)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            TextField("一句话介绍（可不填）", text: $intro).textFieldStyle(.roundedBorder).onSubmit(save)
            ProjectStylePicker(icon: $icon, color: $color, cell: 30)
            if project == nil { folderRow }
            HStack {
                Spacer()
                // Esc 由弹层接（关掉即取消）
                Button("取消", role: .cancel) { close() }
                Button(project == nil ? "创建" : "保存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(palette.desk)
        .onAppear {
            guard let project else { return }
            name = project.name
            intro = project.intro ?? ""
            icon = ProjectIcon(stored: project.icon)
            color = project.color
        }
    }

    /// 文件夹：没选时是"选择…"，选了写末段名（悬停看完整路径）并可清掉。
    private var folderRow: some View {
        HStack(spacing: 8) {
            Label("文件夹", icon: .folder).foregroundStyle(palette.ink2)
            Spacer()
            if let folder {
                Text(URL(filePath: folder).lastPathComponent).lineLimit(1).help(folder)
                Button("不绑了", icon: .clear) { self.folder = nil }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(palette.ink2)
            } else {
                Button("选择…") { Task { folder = await ProjectDirectory.pick() } }
            }
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let project = project, intro = intro, icon = icon, color = color, folder = folder
        workspace.attempt {
            let id = try await workspace.saveProject(project, name: name, intro: intro, icon: icon, color: color)
            if project == nil {
                if let folder { try await workspace.services.store.setDirectory(folder, for: id) }
                workspace.show(.project(id))
            }
        }
        close()
    }
}
#endif
