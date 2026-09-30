#if os(iOS)
import CueStore
import SwiftUI

nonisolated private struct TasksData: Sendable {
    var open: [CueTask]
    var completed: [CueTask]
    var projects: [Project]
}

/// 全部任务：按项目分组（未归属在前），最近完成的收在最后。左滑删除，右滑完成，长按转为卡片或换项目。
struct TasksScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var data: TasksData?
    @State private var showsCompleted = false

    nonisolated private static let completedLimit = 30

    var body: some View {
        List {
            Section { NewTaskLine(project: nil) }
            if let data {
                if data.open.isEmpty {
                    Text("没有未完成的任务").foregroundStyle(.secondary)
                }
                let live = Set(data.projects.map(\.id))
                // 挂在回收站项目上的任务归到"未归属"，否则会从列表里消失
                let groups = Dictionary(grouping: data.open) { $0.projectID.flatMap { live.contains($0) ? $0 : nil } }
                ForEach([nil] + data.projects.map(\.id), id: \.self) { (owner: UUID?) in
                    if let tasks = groups[owner] {
                        let project = data.projects.first { $0.id == owner }
                        Section {
                            ForEach(tasks) { task in row(task, projects: data.projects) }
                        } header: {
                            HStack(spacing: 6) {
                                if let project { ProjectGlyph(project: project, size: 12) }
                                Text(project?.name ?? "未归属")
                                Text("\(tasks.count)").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                if !data.completed.isEmpty {
                    Section(isExpanded: $showsCompleted) {
                        ForEach(data.completed) { task in row(task, projects: data.projects) }
                    } header: {
                        Text("最近完成 \(data.completed.count)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("任务")
        .observing(services.store, [.tasks, .projects], into: $data, onError: workspace.fail) { store in
            TasksData(
                open: try store.tasks(), completed: Array(try store.completedTasks().prefix(Self.completedLimit)),
                projects: try store.projects())
        }
    }

    private func row(_ task: CueTask, projects: [Project]) -> some View {
        TaskLine(task: task)
            .swipeActions(edge: .leading) {
                Button(task.completedAt == nil ? "完成" : "未完成", systemImage: "checkmark") { workspace.attempt { try await workspace.toggle(task) } }
                    .tint(.green)
            }
            .swipeActions(edge: .trailing) {
                Button("删除", systemImage: "trash", role: .destructive) {
                    let id = task.id
                    workspace.perform { try await $0.deleteTask(id) }
                }
            }
            .contextMenu { TaskActions(task: task, projects: projects) }
    }
}

/// 一条任务：圆圈勾选完成。
struct TaskLine: View {
    let task: CueTask
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let done = task.completedAt != nil
        HStack(spacing: 10) {
            Button { workspace.attempt { try await workspace.toggle(task) } } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? palette.ink2 : palette.ink3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "标为未完成" : "完成")
            Text(task.content)
                .font(.body).strikethrough(done)
                .foregroundStyle(done ? palette.ink3 : palette.ink)
                .lineLimit(2)
        }
    }
}

private struct TaskActions: View {
    let task: CueTask
    let projects: [Project]
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let id = task.id, content = task.content, project = task.projectID
        Button("转为卡片", systemImage: "rectangle.on.rectangle") {
            workspace.attempt {
                _ = try await workspace.createCard(body: content, in: project)
                try await workspace.services.store.deleteTask(id)
            }
        }
        Menu("移到项目", systemImage: "folder") {
            Button("未归属") { workspace.perform { try await $0.updateTask(id) { $0.projectID = nil } } }
            ForEach(projects) { target in
                Button(target.name) { workspace.perform { try await $0.updateTask(id) { $0.projectID = target.id } } }
                    .disabled(target.id == project)
            }
        }
        Button("删除", systemImage: "trash", role: .destructive) { workspace.perform { try await $0.deleteTask(id) } }
    }
}

/// 一行新建任务：↩ 添加并保持焦点，便于连续输入。
struct NewTaskLine: View {
    let project: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(palette.ink3).frame(minWidth: 28).accessibilityHidden(true)
            TextField("添加任务", text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
        }
    }

    private func add() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        text = ""
        focused = true
        let project = project
        workspace.attempt { _ = try await workspace.createTask(content, in: project) }
    }
}
#endif
