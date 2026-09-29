#if os(macOS)
import CuePi
import CueStore
import SwiftUI

nonisolated private struct TasksData: Sendable {
    var open: [CueTask]
    var completed: [CueTask]
    var projects: [Project]
}

/// 右上角面板：全部任务，按项目分组（未归属在前），最近完成的折叠在底部。
struct TasksPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: TasksData?
    @State private var showsCompleted = false

    nonisolated private static let completedLimit = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("任务").font(.system(size: 15, weight: .semibold))
                if let data { Text("\(data.open.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
                Spacer()
                Button("关闭", systemImage: "xmark") { workspace.overlay = nil }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
            NewTaskField(project: workspace.currentProject)
                .padding(.horizontal, 20).padding(.bottom, 6)
            ScrollView {
                if let data { list(data) }
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
        .glass(in: .rect(cornerRadius: 26))
        .observing(services.store, [.tasks, .projects], into: $data, onError: workspace.fail) { store in
            TasksData(
                open: try store.tasks(), completed: Array(try store.completedTasks().prefix(Self.completedLimit)),
                projects: try store.projects())
        }
    }

    @ViewBuilder
    private func list(_ data: TasksData) -> some View {
        // 挂在回收站项目上的任务归到"未归属"显示，否则会从面板里消失
        let live = Set(data.projects.map(\.id))
        let groups = Dictionary(grouping: data.open) { $0.projectID.flatMap { live.contains($0) ? $0 : nil } }
        let owners: [UUID?] = [nil] + data.projects.map(\.id)
        LazyVStack(alignment: .leading, spacing: 0) {
            if data.open.isEmpty {
                Text("没有未完成的任务").font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            ForEach(owners.filter { groups[$0] != nil }, id: \.self) { owner in
                let project = data.projects.first { $0.id == owner }
                HStack(spacing: 6) {
                    if project != nil { ProjectGlyph(project: project, size: 11) }
                    Text(project?.name ?? "未归属")
                    Text("\(groups[owner]?.count ?? 0)").foregroundStyle(.tertiary)
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                ForEach(groups[owner] ?? []) { task in
                    TaskRow(task: task, projects: data.projects).padding(.horizontal, 20)
                }
            }
            if !data.completed.isEmpty {
                Button {
                    withAnimation(Motion.quick) { showsCompleted.toggle() }
                } label: {
                    Label("最近完成 \(data.completed.count)", systemImage: showsCompleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
                if showsCompleted {
                    ForEach(data.completed) { task in
                        TaskRow(task: task, projects: data.projects).padding(.horizontal, 20)
                    }
                }
            }
        }
        .padding(.bottom, 12)
    }
}

/// 一条任务：勾选完成；关联了 Pi 会话时显示其状态点。右键可发给 Pi、转为卡片、换项目、删除。
struct TaskRow: View {
    let task: CueTask
    var projects: [Project] = []
    var compact = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        let done = task.completedAt != nil
        let session = task.piSessionID.flatMap { id in services.pi.sessions.first { $0.sessionID == id } }
        HStack(spacing: compact ? 8 : 10) {
            Button { toggle() } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: compact ? 12 : 14))
                    .foregroundStyle(done ? AnyShapeStyle(palette.ink2) : AnyShapeStyle(palette.ink3))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(done ? "标为未完成" : "完成")
            if editing {
                TextField("任务", text: $draft).textFieldStyle(.plain).onSubmit(commit)
                    .onExitCommand { editing = false }
            } else {
                Text(task.content)
                    .font(.system(size: 13)).strikethrough(done).foregroundStyle(done ? palette.ink3 : palette.ink)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { draft = task.content; editing = true }
            }
            Spacer(minLength: 4)
            if task.piSessionID != nil { PiDot(state: session?.state, size: 6).help(session?.state.label ?? "会话已结束") }
        }
        .frame(minHeight: compact ? 22 : 28)
        .contentShape(.rect)
        .contextMenu { menu }
    }

    @ViewBuilder private var menu: some View {
        let id = task.id, content = task.content, project = task.projectID
        Button("编辑") { draft = content; editing = true }
        if !services.pi.sessions.isEmpty {
            Menu("发给 Pi") {
                ForEach(services.pi.sessions) { session in
                    Button(Workspace.sessionName(session)) { sendToPi(session) }
                }
            }
        }
        Button("转为卡片") {
            workspace.attempt {
                _ = try await workspace.createCard(body: content, in: project)
                try await workspace.services.store.deleteTask(id)
            }
        }
        if !projects.isEmpty {
            Menu("移到项目") {
                Button("未归属") { workspace.perform { try await $0.updateTask(id) { $0.projectID = nil } } }
                ForEach(projects) { target in
                    Button(target.name) { workspace.perform { try await $0.updateTask(id) { $0.projectID = target.id } } }
                        .disabled(target.id == project)
                }
            }
        }
        Divider()
        Button("删除", role: .destructive) { workspace.perform { try await $0.deleteTask(id) } }
    }

    private func toggle() {
        let id = task.id, completed: Date? = task.completedAt == nil ? .now : nil
        workspace.perform { try await $0.updateTask(id) { $0.completedAt = completed } }
    }

    private func commit() {
        editing = false
        let id = task.id, content = draft.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, content != task.content else { return }
        workspace.perform { try await $0.updateTask(id) { $0.content = content } }
    }

    /// 发出后把任务关联到该会话，之后显示会话状态。
    private func sendToPi(_ session: CuePi.PiSession) {
        let id = task.id, sessionID = session.sessionID
        Task {
            guard await workspace.send(task.content, via: .pi(session.id), task: id) else { return }
            workspace.perform { try await $0.updateTask(id) { $0.piSessionID = sessionID } }
        }
    }
}

/// 一行新建任务：↩ 添加，保持焦点以便连续输入。
struct NewTaskField: View {
    let project: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.ink3)
            TextField("添加任务", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                .onSubmit(add)
        }
        .frame(minHeight: 24)
    }

    private func add() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        text = ""
        let project = project
        workspace.attempt { _ = try await workspace.createTask(content, in: project) }
    }
}
#endif
