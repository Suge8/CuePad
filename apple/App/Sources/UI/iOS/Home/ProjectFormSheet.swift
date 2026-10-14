#if os(iOS)
import CueStore
import SwiftUI

/// 新建或编辑项目：名称、一句话介绍、图标、颜色；新建时还可以从 Mac 上已知的文件夹里选一个（可不选，之后在项目菜单里绑也行）。
struct ProjectFormSheet: View {
    let project: Project?
    var created: ((UUID) -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var name = ""
    @State private var intro = ""
    @State private var icon = "folder"
    @State private var color = ProjectStylePicker.colors[0].hex
    /// 新建时选的文件夹；项目建好后请那台 Mac 绑。编辑项目不在这里改绑定，项目菜单里改。
    @State private var folder: ProjectFolders.Candidate?

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField("名称", text: $name).submitLabel(.done).onSubmit(save)
                        TextField("一句话介绍（可不填）", text: $intro, axis: .vertical).lineLimit(1...3)
                    }
                    Section("图标与颜色") { ProjectStylePicker(icon: $icon, color: $color, cell: 44) }
                    if project == nil {
                        Section {
                            NavigationLink {
                                FolderCandidateList(project: nil, closesOnChoose: true) { folder = $0 }.navigationTitle("文件夹")
                            } label: {
                                LabeledContent("文件夹（可不选）", value: folder?.folder ?? "")
                            }
                            if folder != nil { Button("不绑了", role: .destructive) { folder = nil } }
                        }
                    }
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
        let project = project, intro = intro, icon = icon, color = color, folder = folder, created = created
        workspace.attempt {
            let id = try await workspace.saveProject(project, name: name, intro: intro, icon: icon, color: color)
            if project == nil, let folder {
                try await workspace.requestFolder(PiBind(project: id, folder: folder.target), title: name, on: folder.hostID)
            }
            if project == nil { created?(id) }
        }
        dismiss()
    }
}
#endif
