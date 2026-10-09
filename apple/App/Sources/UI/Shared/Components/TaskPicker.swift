import CueStore
import SwiftUI

/// "挂到任务"：给一条灵感挑一个任务，选中后它挂到那个任务下成为提示词（`Workspace.attach`，与拖到任务行上同一条通路，提示可撤销）。
/// 最上面"新建任务…"（建在灵感所在的项目，标题先填灵感的标题）；下面是没做完的任务，按项目分组——灵感所在项目的在前（`AttachTargets`），
/// 子任务写上它的上级；可搜。iOS 与 Mac 同一个面板，由窗口的根视图按 `Workspace.attaching` 弹出。
struct TaskPicker: View {
    let idea: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var groups: [TaskGroup]?
    @State private var text = ""
    @State private var naming = false
    @State private var title = ""

    private static let macSize = CGSize(width: 440, height: 520)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        title = idea.title
                        naming = true
                    } label: {
                        Label("新建任务…", systemImage: "plus").foregroundStyle(palette.ink).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(palette.paper)
                }
                ForEach(shown, id: \.projectID) { group in
                    Section {
                        ForEach(group.tasks) { task in row(task) }
                    } header: {
                        HStack(spacing: 6) {
                            ProjectGlyph(project: workspace.catalog?.project(group.projectID), size: 12)
                            Text(workspace.catalog?.project(group.projectID)?.name ?? CaptureCopy.inbox)
                        }
                    }
                }
                if groups?.isEmpty == true {
                    Text("还没有没做完的任务，新建一个吧").foregroundStyle(palette.ink3).listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(palette.desk)
            .navigationTitle("挂到任务")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索任务")
            #else
            .searchable(text: $text, prompt: "搜索任务")
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
            }
            .alert("新建任务", isPresented: $naming) {
                TextField("这件事是…", text: $title)
                Button("取消", role: .cancel) {}
                Button("新建并挂上", action: createAndAttach)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("这条灵感会成为它的第一条提示词")
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(width: Self.macSize.width, height: Self.macSize.height)
        #endif
        .observing(services.store, [.cards, .projects], id: idea.id, into: $groups, onError: workspace.fail) { [idea] store in
            try AttachTargets.read(for: idea, from: store)
        }
    }

    private struct Shown {
        var projectID: UUID?
        var tasks: [Card]
    }

    /// 按搜索词筛过的分组（空的组不显示）。
    private var shown: [Shown] {
        let words = text.trimmingCharacters(in: .whitespaces)
        return (groups ?? []).compactMap { group in
            let tasks = words.isEmpty ? group.tasks : group.tasks.filter { $0.title.localizedCaseInsensitiveContains(words) }
            return tasks.isEmpty ? nil : Shown(projectID: group.projectID, tasks: tasks)
        }
    }

    private func row(_ task: Card) -> some View {
        let parent = task.parentID.flatMap { id in groups?.lazy.flatMap(\.tasks).first { $0.id == id } }
        return Button { attach(to: task.id) } label: {
            HStack(spacing: 10) {
                TaskRingView(status: task.status, ring: .plain, done: false, size: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).foregroundStyle(palette.ink).lineLimit(2)
                    if let parent { Text("在「\(parent.title)」下").font(.caption).foregroundStyle(palette.ink3).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.paper)
    }

    private func attach(to task: UUID) {
        let id = idea.id
        dismiss()
        workspace.attempt { try await workspace.attach(id, to: task) }
    }

    private func createAndAttach() {
        let id = idea.id, title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
        workspace.attempt { try await workspace.attachToNewTask(id, title: title) }
    }
}
