#if os(iOS)
import CueStore
import SwiftUI

/// 新建或编辑项目：名称、一句话介绍、图标、颜色。
struct ProjectFormSheet: View {
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var name = ""
    @State private var intro = ""
    @State private var icon = "folder"
    @State private var color = ProjectStylePicker.colors[0].hex

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("名称", text: $name).submitLabel(.done).onSubmit(save)
                        TextField("一句话介绍（可不填）", text: $intro, axis: .vertical).lineLimit(1...3)
                    }
                    Section("图标与颜色") { ProjectStylePicker(icon: $icon, color: $color, cell: 44) }
                }
                .listRowBackground(palette.paper)
            }
            .deskBackground()
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
        // 只给大尺寸：半屏放不下名称与全部图标、颜色，小屏 iPhone 上当前的颜色会落在半屏以下
        .presentationDetents([.large])
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
        workspace.attempt { _ = try await workspace.saveProject(project, name: name, intro: intro, icon: icon, color: color) }
        dismiss()
    }
}
#endif
