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
    @Environment(\.palette) private var palette
    @State private var data: TasksData?
    @State private var showsCompleted = false

    nonisolated private static let completedLimit = 30

    var body: some View {
        List {
            Section { NewTaskLine(project: nil, projects: data?.projects).listRowBackground(palette.paper) }
            if let data {
                if data.open.isEmpty {
                    Text(data.completed.isEmpty ? "还没有任务" : "全部完成了").foregroundStyle(palette.ink2)
                        .listRowBackground(palette.paper)
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
                                Text("\(tasks.count)").foregroundStyle(palette.ink3)
                            }
                        }
                    }
                }
                if !data.completed.isEmpty {
                    Section {
                        if showsCompleted { ForEach(data.completed) { task in row(task, projects: data.projects) } }
                    } header: {
                        Button {
                            withAnimation(Motion.quick) { showsCompleted.toggle() }
                        } label: {
                            HStack(spacing: 6) {
                                Text("最近完成 \(data.completed.count)")
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .rotationEffect(.degrees(showsCompleted ? 90 : 0)).accessibilityHidden(true)
                                Spacer()
                            }
                            .frame(minHeight: 44).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showsCompleted ? "已展开" : "已折叠")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .deskBackground()
        .bottomEdgeFade()
        .navigationTitle("任务")
        .animation(.easeOut(duration: 0.2), value: data.map { $0.open.map(\.id) + $0.completed.map(\.id) })
        .observing(services.store, [.tasks, .projects], into: $data, onError: workspace.fail) { store in
            TasksData(
                open: try store.tasks(), completed: Array(try store.completedTasks().prefix(Self.completedLimit)),
                projects: try store.projects())
        }
    }

    private func row(_ task: CueTask, projects: [Project]) -> some View {
        TaskLine(task: task)
            .listRowBackground(palette.paper)
            .swipeActions(edge: .leading) {
                Button(task.completedAt == nil ? "完成" : "未完成", systemImage: "checkmark") { workspace.attempt { try await workspace.toggle(task) } }
                    .tint(palette.accent)
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

/// 一条任务：点圆圈立即显示完成（对勾、删除线、成功触感），停留片刻再从列表移出；这段时间里再点一下就撤销。
/// 已完成的任务点一下立即恢复。
struct TaskLine: View {
    let task: CueTask
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    private enum Phase { case idle, pending, committed }
    /// pending：已显示完成、还没写入；committed：已写入，等列表把它移走。
    @State private var phase = Phase.idle

    /// 完成后停留多久再移出：够看清对勾、来得及反悔。
    private static let linger: Duration = .milliseconds(900)

    var body: some View {
        let done = task.completedAt != nil || phase != .idle
        HStack(spacing: 2) {
            Button(action: tap) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? palette.accent : palette.ink3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: phase) { $0 == .idle && $1 == .pending }
            .accessibilityLabel(phase == .pending ? "撤销完成" : done ? "标为未完成" : "完成")
            Text(task.content.textGlyphs)
                .font(.body).strikethrough(done)
                .foregroundStyle(done ? palette.ink3 : palette.ink)
                .lineLimit(2)
        }
        .animation(.easeOut(duration: 0.12), value: done)
        .task(id: phase) {
            guard phase == .pending else { return }
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            commit()
        }
        // 移出前就离开了页面：照样写入，不丢这次勾选
        .onDisappear { if phase == .pending { commit() } }
        // 完成状态以 Store 为准：写入落地或别处恢复为未完成时，这一行回到普通状态
        .onChange(of: task.completedAt) { phase = .idle }
    }

    private func tap() {
        switch (task.completedAt, phase) {
        case (.some, _): workspace.attempt { try await workspace.toggle(task) }
        case (nil, .idle): phase = .pending
        case (nil, .pending): phase = .idle
        case (nil, .committed): break
        }
    }

    /// 写入失败时这一行恢复为未完成，错误照常提示。
    private func commit() {
        phase = .committed
        Task {
            do {
                try await workspace.toggle(task)
            } catch {
                phase = .idle
                workspace.fail(error)
            }
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
        HStack(spacing: 2) {
            Image(systemName: "plus").foregroundStyle(palette.ink3).frame(width: 44).accessibilityHidden(true)
            TextField("添加任务", text: $text)
                .frame(minHeight: 44)
                .contentShape(.rect)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
            if let projects, !projects.isEmpty {
                Menu {
                    Button("未归属") { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 11)
                        Text(current?.name ?? "未归属").lineLimit(1)
                    }
                    .font(.footnote).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(palette.fill, in: .capsule)
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .accessibilityLabel("挂到 \(projects.first { $0.id == target }?.name ?? "未归属")")
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
#endif
