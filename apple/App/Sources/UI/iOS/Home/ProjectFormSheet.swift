#if os(iOS)
import CueStore
import SwiftUI

/// 新建或编辑项目：名称、图标、颜色。
struct ProjectFormSheet: View {
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "folder"
    @State private var color = ProjectStylePicker.colors[0].hex

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name).submitLabel(.done).onSubmit(save)
                Section("图标与颜色") { ProjectStylePicker(icon: $icon, color: $color, cell: 44) }
            }
            .navigationTitle(project == nil ? "新建项目" : "编辑项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(project == nil ? "创建" : "保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
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
        workspace.attempt { _ = try await workspace.saveProject(project, name: name, icon: icon, color: color) }
        dismiss()
    }
}
#endif
