#if os(macOS)
import CueStore
import SwiftUI

/// 右上角面板：顶上一行快速添加；下面是共用的任务看板（`TaskBoard`）——进行中、待办、最近完成（折起），跨项目，
/// 每条写所在项目，交给 Pi 的写那个会话此刻的状态。点圆圈完成（完成的回到待办），右键是 `TaskActions`。
struct TasksPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var board: TaskBoard?
    @State private var showsCompleted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("任务").font(.system(size: 15, weight: .semibold))
                if let board { Text("\(board.inProgress.count + board.todo.count)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
                Spacer()
                Button("关闭", systemImage: "xmark") { workspace.overlay = nil }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
            NewTaskField(project: workspace.currentProject, choosesProject: true)
                .padding(.horizontal, 20).padding(.bottom, 6)
            ScrollView {
                if let board { list(board) }
            }
        }
        .frame(width: 360)
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: true)
        .glass(in: .rect(cornerRadius: 26))
        .observing(services.store, [.tasks, .projects, .piSessionStates], into: $board, onError: workspace.fail) {
            try TaskBoard.read(from: $0)
        }
    }

    // 不用 LazyVStack：面板高度随内容撑开，懒加载栈在行于两组之间移动、展开"最近完成"时会漏画或留下旧状态的行。
    // 任务量小，普通 VStack 足够。
    private func list(_ board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if board.inProgress.isEmpty && board.todo.isEmpty {
                Text(board.done.isEmpty ? "还没有任务，在上面写一条" : "全部完成了").font(.system(size: 13)).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            section("进行中", board.inProgress)
            section("待办", board.todo)
            if !board.done.isEmpty {
                Button {
                    withAnimation(Motion.quick) { showsCompleted.toggle() }
                } label: {
                    Label("最近完成 \(board.done.count)", systemImage: showsCompleted ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
                .accessibilityValue(showsCompleted ? "已展开" : "已折叠")
                if showsCompleted { rows(board.done) }
            }
        }
        .padding(.bottom, 12)
        .animation(Motion.quick, value: [board.inProgress, board.todo, board.done].flatMap { $0.map(\.id) })
    }

    @ViewBuilder private func section(_ title: String, _ items: [TaskBoard.Row]) -> some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Text(title)
                Text("\(items.count)").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            rows(items)
        }
    }

    private func rows(_ items: [TaskBoard.Row]) -> some View {
        ForEach(items) { row in
            TaskRow(task: row.task, project: row.project, session: row.session.map(workspace.withLiveState)).padding(.horizontal, 20)
        }
    }
}

/// 一条任务：圆圈分三态（待办空心、进行中半满、完成对勾），点它完成（完成的回到待办），双击文字编辑；
/// 第二行写所在项目（面板里跨项目时）与交给 Pi 的会话此刻的状态。右键是 `TaskActions`。
struct TaskRow: View {
    let task: CueTask
    /// 跨项目列着时写上所在项目；项目页里不写。
    var project: Project?
    /// 交给 Pi 的任务：那个会话此刻的状态。
    var session: PiSessionState?
    var compact = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var editing = false
    @State private var draft = ""

    private var done: Bool { task.status == .done }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 8 : 10) {
            Button { toggle() } label: {
                Image(systemName: done ? "checkmark.circle.fill" : task.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                    .font(.system(size: compact ? 12 : 14))
                    .foregroundStyle(done ? palette.accent : task.status == .inProgress ? palette.ink2 : palette.ink3)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .accessibilityLabel(done ? "回到待办" : "完成")
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("任务", text: $draft).textFieldStyle(.plain).onSubmit(commit)
                        .onExitCommand { editing = false }
                } else {
                    Text(task.content)
                        .font(.system(size: 13)).strikethrough(done).foregroundStyle(done ? palette.ink3 : palette.ink)
                        .lineLimit(2)
                        .onTapGesture(count: 2, perform: beginEditing)
                }
                if project != nil || (session != nil && !done) { detail }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, compact ? 1 : 3)
        .frame(minHeight: compact ? 22 : 28)
        .contentShape(.rect)
        .contextMenu { TaskActions(task: task, edit: beginEditing) }
        // 读屏：整行一个元素"任务内容，项目，Pi 在做什么"，值是状态，默认动作切换完成（文案见 TaskSpeech）；编辑时露出输入框
        .accessibilityElement(children: editing ? .contain : .ignore)
        .accessibilityLabel([task.content, project?.name, session.map { $0.state.presence }].compactMap { $0 }.joined(separator: "，"))
        .accessibilityValue(TaskSpeech.value(task.status))
        .accessibilityAction { toggle() }
        .accessibilityAction(named: TaskSpeech.toggle(done: done), toggle)
        .accessibilityAction(named: "编辑", beginEditing)
    }

    /// 第二行：所在项目、交给 Pi 的会话此刻的状态（"Pi 正在工作 · 已运行 4:02"）。
    private var detail: some View {
        HStack(spacing: 10) {
            if let project {
                HStack(spacing: 4) {
                    ProjectGlyph(project: project, size: 10)
                    Text(project.name).lineLimit(1)
                }
                .foregroundStyle(palette.ink3)
            }
            if let session, !done {
                HStack(spacing: 4) {
                    PiStateDot(state: session.state, size: 5)
                    Text(session.state.presence).foregroundStyle(session.state.tint(palette))
                    PiElapsed(session: session, font: .system(size: 11))
                }
                .help("交给了 Pi 会话「\(session.title)」")
            }
        }
        .font(.system(size: 11))
    }

    private func beginEditing() {
        draft = task.content
        editing = true
    }

    private func toggle() {
        let task = task
        workspace.attempt { try await workspace.toggle(task) }
    }

    private func commit() {
        editing = false
        let id = task.id, content = draft.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty, content != task.content else { return }
        workspace.perform { try await $0.updateTask(id) { $0.content = content } }
    }
}

/// 一行新建任务：↩ 添加，保持焦点以便连续输入。`choosesProject` 时右边可换落到哪个项目（任务面板跨项目）。
struct NewTaskField: View {
    let project: UUID?
    var choosesProject = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosen: UUID??

    private var target: UUID? { chosen ?? project }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField("添加任务", text: $text).textFieldStyle(.plain).font(.system(size: 13))
                .accessibilityLabel("添加任务")
                .onSubmit(add)
            if choosesProject, let projects = workspace.catalog?.projects, !projects.isEmpty {
                Menu {
                    Button("未归档") { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 10)
                        Text(current?.name ?? "未归档").lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(palette.fill.opacity(2), in: .capsule)
                    .contentShape(.capsule)
                }
                .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("挂到 \(projects.first { $0.id == target }?.name ?? "未归档")")
            }
        }
        .frame(minHeight: 24)
    }

    private func add() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        text = ""
        let project = target
        workspace.attempt { _ = try await workspace.createTask(content, in: project) }
    }
}
#endif
