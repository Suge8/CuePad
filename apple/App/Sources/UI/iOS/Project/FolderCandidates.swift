#if os(iOS)
import CueStore
import SwiftUI

/// 手机上给项目选文件夹：候选是 Mac 上已知的文件夹（跑过 Agent 的、别的项目绑着的，规则见 `ProjectFolders.candidates`），
/// 手机看不到 Mac 的完整路径，所以只有名字；选中后请那台 Mac 解析成完整路径再绑。同一台 Mac 上只列一次，Mac 不止一台时按 Mac 分组。
/// `project` 是给哪个项目选（它在那台 Mac 上已绑着的不列）；新建项目时还没有项目，为 nil。`closesOnChoose`：选中后收起自己（推入页用）。
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

    private var groups: [(host: String?, items: [ProjectFolders.Candidate])] {
        let hosts = Set(shown.map(\.hostID))
        guard hosts.count > 1 else { return [(nil, shown)] }
        return hosts.sorted().map { host in
            let items = shown.filter { $0.hostID == host }
            return (items.first?.macName, items)
        }
    }

    var body: some View {
        List {
            ForEach(groups, id: \.host) { group in
                Section(group.host ?? "") {
                    ForEach(group.items) { candidate in
                        Button { pick(candidate) } label: {
                            HStack(spacing: 10) {
                                Image(.folder).foregroundStyle(palette.ink3).accessibilityHidden(true)
                                Text(candidate.folder).foregroundStyle(palette.ink).lineLimit(1)
                                Spacer(minLength: 8)
                                if let usedBy = candidate.usedBy { Text("「\(usedBy)」在用").font(.footnote).foregroundStyle(palette.ink3).lineLimit(1) }
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

/// 项目操作菜单里"绑定文件夹…／换文件夹…"弹出的页：选一个候选，请那台 Mac 绑；Mac 绑好（结果写回）才收起，没成功就在下面写原因、可以再选。
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
                .navigationTitle("\(project.name) 的文件夹")
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
            HStack(spacing: 8) {
                Spinner(.small)
                Text("Mac 正在绑定「\(folder)」…").font(.footnote).foregroundStyle(palette.ink2)
            }
            .frame(maxWidth: .infinity).padding(14).background(.bar)
        case .failed(let reason):
            Text(reason).font(.footnote).foregroundStyle(palette.failure)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(.bar)
        }
    }

    private func bind(_ candidate: ProjectFolders.Candidate) {
        phase = .binding(candidate.folder)
        let id = project.id, name = project.name
        Task {
            do {
                try await workspace.requestFolder(PiBind(project: id, folder: candidate.target), title: name, on: candidate.hostID)
                dismiss()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
#endif
