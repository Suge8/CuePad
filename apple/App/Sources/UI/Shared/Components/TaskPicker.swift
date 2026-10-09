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
    #if os(macOS)
    @FocusState private var searching: Bool
    @State private var hovered: UUID?
    #endif

    private static let macSize = CGSize(width: 440, height: 540)

    var body: some View {
        content
            .alert("新建任务", isPresented: $naming) {
                TextField("这件事是…", text: $title)
                Button("取消", role: .cancel) {}
                Button("新建并挂上", action: createAndAttach)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: {
                Text("这条灵感会成为它的第一条提示词")
            }
            .observing(services.store, [.cards, .projects], id: idea.id, into: $groups, onError: workspace.fail) { [idea] store in
                try AttachTargets.read(for: idea, from: store)
            }
    }

    private var newTask: some View {
        Button {
            title = idea.title
            naming = true
        } label: {
            Label("新建任务…", systemImage: "plus").foregroundStyle(palette.ink).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func header(_ projectID: UUID?) -> some View {
        HStack(spacing: 6) {
            ProjectGlyph(project: workspace.catalog?.project(projectID), size: 12)
            Text(workspace.catalog?.project(projectID)?.name ?? CaptureCopy.inbox)
        }
    }

    private static let empty = "还没有没做完的任务，新建一个吧"

    #if os(iOS)
    private var content: some View {
        NavigationStack {
            List {
                Section { newTask.listRowBackground(palette.paper) }
                ForEach(shown, id: \.projectID) { group in
                    Section {
                        ForEach(group.tasks) { task in row(task).listRowBackground(palette.paper) }
                    } header: {
                        header(group.projectID)
                    }
                }
                if groups?.isEmpty == true {
                    Text(Self.empty).foregroundStyle(palette.ink3).listRowBackground(Color.clear)
                }
            }
            .listSectionSpacing(.compact)
            // 搜索框下面直接是"新建任务…"，不留分组默认的一大段上边距
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(palette.desk)
            .navigationTitle("挂到任务")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
    #else
    /// Mac 与手机同一种质感：标题居中、搜索占满一行，"新建任务…"单独一张纸，每个项目一张纸、行间不画线；Esc 关闭。
    private var content: some View {
        VStack(spacing: 14) {
            Text("挂到任务").font(Typography.toolbarTitle).foregroundStyle(palette.ink)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3).accessibilityHidden(true)
                TextField("搜索任务", text: $text).textFieldStyle(.plain).focused($searching)
            }
            .font(Typography.body)
            .padding(.horizontal, 12).frame(height: 34)
            .background(palette.fill, in: .rect(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    newTask.font(Typography.body).padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .paper(radius: 12)
                    ForEach(shown, id: \.projectID) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            header(group.projectID).font(Typography.label).foregroundStyle(palette.ink3).padding(.leading, 4)
                            VStack(spacing: 0) {
                                ForEach(group.tasks) { task in
                                    row(task).padding(.horizontal, 10).padding(.vertical, 9)
                                        .background(hovered == task.id ? palette.fill : .clear, in: .rect(cornerRadius: 8, style: .continuous))
                                        .onHover { hovered = $0 ? task.id : hovered == task.id ? nil : hovered }
                                }
                            }
                            .padding(4)
                            .paper(radius: 12)
                        }
                    }
                    if groups?.isEmpty == true {
                        Text(Self.empty).font(Typography.secondary).foregroundStyle(palette.ink3).frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
        }
        .padding(.top, 18)
        .frame(width: Self.macSize.width, height: Self.macSize.height)
        .background(palette.desk)
        .background { Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).hidden() }
        .onAppear { searching = true }
    }
    #endif

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
                    Text(task.title).font(Typography.body).foregroundStyle(palette.ink).lineLimit(2)
                    if let parent { Text("在「\(parent.title)」下").font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
