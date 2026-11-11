#if os(macOS)
import CueStore
import SwiftUI

enum ProjectDirectory {
    static func pick() async -> String? {
        await FilePicker.folder(message: "选择这个项目的文件夹，在其中运行的 Agent 会话会归到这个项目，新会话也开在这里")?
            .path(percentEncoded: false)
    }

    static func choose(for project: UUID, workspace: Workspace) {
        workspace.attempt {
            guard let path = await pick() else { return }
            try await workspace.services.store.setDirectory(path, for: project)
        }
    }
}

struct ProjectForm: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @State private var draft: ProjectDraft
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

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text, palette: palette)
            .textFieldStyle(.plain).font(Typography.body).foregroundStyle(palette.ink)
            .padding(.horizontal, Spacing.inset)
            .frame(height: ControlSize.regular.height)
            .panelFieldSurface()
            .onSubmit(save)
    }

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
