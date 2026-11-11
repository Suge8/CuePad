#if os(iOS)
import CueStore
import SwiftUI

/// 手机看不到 Mac 的完整路径，所以只有名字；选中后请那台 Mac 解析成完整路径再绑。`project` 在新建项目时还没有，为 nil。
struct FolderCandidateList: View {
    let project: UUID?
    var closesOnChoose = false
    let choose: (ProjectFolders.Candidate) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [ProjectFolders.Candidate]?
    @State private var query = ""

    private var shown: [ProjectFolders.Candidate] {
        let text = query.trimmingCharacters(in: .whitespaces)
        return (candidates ?? []).filter { text.isEmpty || $0.folder.localizedStandardContains(text) }
    }

    private var groups: [ProjectFolders.CandidateGroup] { ProjectFolders.candidateGroups(shown) }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.name ?? "") {
                    ForEach(group.items) { candidate in
                        Button { pick(candidate) } label: {
                            HStack(spacing: Spacing.item) {
                                Image(.folder).foregroundStyle(palette.ink3)
                                Text(candidate.folder).foregroundStyle(palette.ink).lineLimit(1)
                                Spacer(minLength: 8)
                                if let usedBy = candidate.usedBy { Text("「\(usedBy)」在用").font(Typography.meta).foregroundStyle(palette.ink3).lineLimit(1) }
                            }
                            .frame(minHeight: 44).contentShape(.rect)
                        }
                    }
                }
            }
            Section {
                EmptyView()
            } footer: {
                Text(candidates?.isEmpty == true
                    ? "还没有 Mac 上跑过 Agent 的文件夹。先在 Mac 上给项目绑定，或在那个文件夹里跑一次 pi。"
                    : "手机上只能从 Mac 上跑过 Agent 的文件夹里选；别的文件夹请在 Mac 上绑定。")
            }
        }
        .listRowBackground(palette.paper)
        .deskBackground()
        .searchable(text: $query, prompt: "搜索文件夹")
        // 搜索框是系统的玻璃，垫不了实底（`GlassInk`）：底边用系统的硬边缘效果把滚到它后面的行压下去，候选的名字不与占位字叠着
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .observing(services.store, id: project, into: $candidates, onError: workspace.fail) {
            [project] store in
            ProjectFolders.candidates(
                folders: try store.sessionFolders(), bindings: try store.directoryBindings(), projects: try store.projects(), excluding: project)
        }
    }

    private func pick(_ candidate: ProjectFolders.Candidate) {
        choose(candidate)
        if closesOnChoose { dismiss() }
    }
}

/// Mac 绑好（结果写回）才收起；没成功就在下面写原因、可以再选。
struct FolderPickerSheet: View {
    let project: Project
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var phase = Phase.idle

    private enum Phase: Equatable {
        case idle
        case binding(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            FolderCandidateList(project: project.id, choose: bind)
                .disabled({ if case .binding = phase { true } else { false } }())
                .navigationTitle("\(project.shownName) 的文件夹")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } } }
                .safeAreaInset(edge: .bottom) { status }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder private var status: some View {
        switch phase {
        case .idle: EmptyView()
        case .binding(let folder):
            HStack(spacing: Spacing.item) {
                Spinner(.small)
                Text("Mac 正在绑定「\(folder)」…").font(Typography.meta).foregroundStyle(palette.ink2)
            }
            .frame(maxWidth: .infinity).padding(Spacing.group).background(.bar)
        case .failed(let reason):
            Text(reason).font(Typography.meta).foregroundStyle(palette.failure)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.group).background(.bar)
        }
    }

    private func bind(_ candidate: ProjectFolders.Candidate) {
        phase = .binding(candidate.folder)
        let id = project.id, name = project.shownName
        Task {
            do {
                try await workspace.requestFolder(BindRequest(project: id, folder: candidate.target), title: name, on: candidate.hostID)
                dismiss()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
#endif
