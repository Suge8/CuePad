#if os(iOS)
import CueStore
import SwiftUI

/// 新建或编辑项目：名称、一句话介绍、图标、颜色；新建时还可以从 Mac 上已知的文件夹里选一个（可不选，之后在项目菜单里绑也行）。
struct ProjectFormSheet: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var draft: ProjectDraft
    /// 新建时选的文件夹；项目建好后请那台 Mac 绑。编辑项目不在这里改绑定，项目菜单里改。
    @State private var folder: ProjectFolders.Candidate?

    init(_ request: ProjectFormRequest) {
        _draft = State(initialValue: ProjectDraft(request))
    }

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField(ProjectDraft.namePrompt, text: $draft.name).submitLabel(.done).onSubmit(save)
                        TextField(ProjectDraft.introPrompt, text: $draft.intro, axis: .vertical).lineLimit(1...3)
                    }
                    Section("图标与颜色") { ProjectStylePicker(icon: $draft.icon, color: $draft.color, cell: 44) }
                    if draft.project == nil {
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
            .navigationTitle(draft.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.confirm, action: save)
                        .disabled(!draft.canSave)
                }
            }
        }
        // 只给大尺寸：半屏放不下名称与全部图标、颜色，小屏 iPhone 上当前的颜色会落在半屏以下
        .presentationDetents([.large])
    }

    private func save() {
        let folder = folder, name = draft.trimmedName
        let saved = draft.save(in: workspace) { id in
            if let folder { try await workspace.requestFolder(PiBind(project: id, folder: folder.target), title: name, on: folder.hostID) }
        }
        if saved { dismiss() }
    }
}
#endif
