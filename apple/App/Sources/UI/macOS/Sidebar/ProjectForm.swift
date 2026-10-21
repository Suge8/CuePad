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
    @Environment(Workspace.self) private var workspace
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @State private var draft: ProjectDraft
    /// 新建时选的文件夹（完整路径）；编辑项目不在这里改绑定，项目菜单里改。
    @State private var folder: String?

    init(_ request: ProjectFormRequest) {
        _draft = State(initialValue: ProjectDraft(request))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.title).font(Typography.bodyStrong)
            TextField(ProjectDraft.namePrompt, text: $draft.name).textFieldStyle(.roundedBorder).onSubmit(save)
            TextField(ProjectDraft.introPrompt, text: $draft.intro).textFieldStyle(.roundedBorder).onSubmit(save)
            ProjectStylePicker(icon: $draft.icon, color: $draft.color, cell: 30)
            if draft.project == nil { folderRow }
            HStack {
                Spacer()
                // Esc 由弹层接（关掉即取消）
                Button("取消", role: .cancel) { close() }
                Button(draft.confirm, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave)
            }
        }
        .padding(20)
        .frame(width: 340)
        .background(palette.desk)
    }

    /// 文件夹：没选时是"选择…"，选了写末段名（悬停看完整路径）并可清掉。
    private var folderRow: some View {
        HStack(spacing: 8) {
            Label("文件夹", icon: .folder).foregroundStyle(palette.ink2)
            Spacer()
            if let folder {
                Text(URL(filePath: folder).lastPathComponent).lineLimit(1).help(folder)
                Button("不绑了", icon: .clear) { self.folder = nil }
                    .labelStyle(.iconOnly).buttonStyle(PressStyle(.inline)).foregroundStyle(palette.ink2)
            } else {
                Button("选择…") { Task { folder = await ProjectDirectory.pick() } }
            }
        }
    }

    private func save() {
        let folder = folder
        let saved = draft.save(in: workspace) { id in
            if let folder { try await workspace.services.store.setDirectory(folder, for: id) }
            workspace.show(.project(id))
        }
        if saved { close() }
    }
}
#endif
