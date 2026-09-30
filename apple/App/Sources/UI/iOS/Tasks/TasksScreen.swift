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
            Section { NewTaskLine(project: nil, projects: data?.projects) }
            if let data {
                if data.open.isEmpty {
                    Text(data.completed.isEmpty ? "还没有任务" : "全部完成了").foregroundStyle(.secondary)
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
        .deskBackground()
        .navigationTitle("任务")
        .animation(Motion.quick, value: data.map { $0.open.map(\.id) + $0.completed.map(\.id) })
        .observing(services.store, [.tasks, .projects], into: $data, onError: workspace.fail) { store in
            TasksData(
                open: try store.tasks(), completed: Array(try store.completedTasks().prefix(Self.completedLimit)),
                projects: try store.projects())
        }
    }

    private func row(_ task: CueTask, projects: [Project]) -> some View {
        TaskLine(task: task)
            .swipeActions(edge: .leading) {
                Button(task.completedAt == nil ? "完成" : "未完成", systemImage: "checkmark") { workspace.toggle(task) }
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
            Button { workspace.toggle(task) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? palette.ink2 : palette.ink3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: done) { !$0 && $1 }
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

    @Environment(Navigation.self) private var navigation

    var body: some View {
        let id = task.id, content = task.content, project = task.projectID
        Button("发到 Mac", systemImage: "paperplane") {
            navigation.outbox = Navigation.Outbox(content: content, task: id, project: project)
        }
        Button("复制", systemImage: "doc.on.doc") {
            workspace.attempt {
                try await workspace.services.send(content, to: .clipboard, task: id)
                workspace.say("已复制")
            }
        }
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

/// 一行新建任务：↩ 添加并保持焦点，便于连续输入。给了 `projects` 时尾部可选挂到哪个项目。
struct NewTaskLine: View {
    let project: UUID?
    var projects: [Project]?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosen: UUID??
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus").foregroundStyle(palette.ink3).frame(minWidth: 28).accessibilityHidden(true)
            TextField("添加任务", text: $text)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
            if let projects, !projects.isEmpty {
                Menu {
                    Button("不挂项目") { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 11)
                        Text(current?.name ?? "不挂项目").lineLimit(1)
                    }
                    .font(.footnote).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(palette.fill, in: .capsule)
                }
                .accessibilityLabel("挂到 \(projects.first { $0.id == target }?.name ?? "不挂项目")")
            }
        }
    }

    private var target: UUID? { chosen ?? project }

    private func add() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        text = ""
        focused = true
        let project = target
        workspace.attempt { _ = try await workspace.createTask(content, in: project) }
    }
}

extension Workspace {
    /// 按 Store 里的当前状态切换：界面手里的副本可能已过时（列表没刷新就又点了一次）。
    /// 与 Mac 端将放进共用 `Workspace` 的勾选方法是同一条规则（TaskToggleTests）；那边落地后删掉这份改用共用的。
    func toggle(_ task: CueTask) {
        let id = task.id
        perform { try await $0.updateTask(id) { $0.completedAt = $0.completedAt == nil ? .now : nil } }
    }
}
#endif
