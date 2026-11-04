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
/// 只给内容，圆角、描边与投影是所在的浮层（`panel`）的；按钮同一档高（`compact`），"创建""保存"是这里唯一的主按钮。
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
        VStack(alignment: .leading, spacing: Spacing.block) {
            Text(draft.title).font(Typography.bodyStrong).foregroundStyle(palette.ink)
            field(ProjectDraft.namePrompt, text: $draft.name)
            field(ProjectDraft.introPrompt, text: $draft.intro)
            ProjectStylePicker(icon: $draft.icon, color: $draft.color, cell: 30)
            if draft.project == nil { folderRow }
            HStack(spacing: Spacing.item) {
                Spacer()
                // Esc 由弹层接（关掉即取消）
                Button("取消", role: .cancel) { close() }
                    .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
                Button(draft.confirm, action: save)
                    .buttonStyle(ControlButtonStyle(kind: .primary, size: .compact))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave)
            }
        }
        .padding(Spacing.panel)
        .frame(width: 340)
    }

    /// 名称与介绍：同一种淡底单行框，与一排控件同高。
    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text, palette: palette)
            .textFieldStyle(.plain).font(Typography.body).foregroundStyle(palette.ink)
            .padding(.horizontal, Spacing.inset)
            .frame(height: ControlSize.regular.height)
            .background(palette.fill, in: Radius.nested)
            .onSubmit(save)
    }

    /// 文件夹：没选时是"选择…"，选了写末段名（悬停看完整路径）并可清掉。
    private var folderRow: some View {
        HStack(spacing: Spacing.item) {
            Label("文件夹", icon: .folder).foregroundStyle(palette.ink2)
            Spacer()
            if let folder {
                Text(URL(filePath: folder).lastPathComponent).lineLimit(1).help(folder)
                Button("不绑了", icon: .clear) { self.folder = nil }
                    .labelStyle(.iconOnly).buttonStyle(PressStyle(.inline)).foregroundStyle(palette.ink2)
            } else {
                Button("选择…") { Task { folder = await ProjectDirectory.pick() } }
                    .buttonStyle(ControlButtonStyle(size: .compact))
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
