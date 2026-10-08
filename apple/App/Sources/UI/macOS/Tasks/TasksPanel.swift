#if os(macOS)
import CueStore
import SwiftUI

/// 右上角面板：顶上一行快速添加；下面是共用的任务看板（`TaskBoard`）——进行中、待办、最近完成（折起），跨项目，
/// 子任务缩进跟在上级下（`TaskOutline`：按住拖动排序、拖到一条上成为它的子任务、横向拖改层级），顶层写所在项目，
/// 交给 Pi 的写那个会话此刻的状态。点圆圈完成（完成的回到待办），点文字整页打开（与灵感同一个纸页），右键是 `CardActions`（缩进与反缩进靠拖放，读屏另有动作）。
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
                if let board { Text("\(board.counts.inProgress + board.counts.todo)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary) }
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
        // 点任务上的会话状态打开它的详情：与侧栏、⌘K 同一个详情弹出层
        .observing(services.store, TaskBoard.tables, into: $board, onError: workspace.fail) {
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
            section("进行中", board.inProgress, count: board.counts.inProgress, in: board)
            section("待办", board.todo, count: board.counts.todo, in: board)
            if !board.done.isEmpty {
                HStack {
                    Button {
                        withAnimation(Motion.quick) { showsCompleted.toggle() }
                    } label: {
                        Label("最近完成 \(board.done.count)", systemImage: showsCompleted ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(showsCompleted ? "已展开" : "已折叠")
                    Spacer()
                    Button("全部归档") { workspace.attempt { try await workspace.archiveCompletedTasks() } }
                        .buttonStyle(.plain).help("把最近完成的任务全部归档：不占列表，照样搜得到")
                }
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
                if showsCompleted { rows(board.done) }
            }
        }
        .padding(.bottom, 12)
        .animation(Motion.quick, value: [board.inProgress, board.todo, board.done].flatMap { $0.map(\.id) })
    }

    @ViewBuilder private func section(_ title: String, _ items: [TaskBoard.Row], count: Int, in board: TaskBoard) -> some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").foregroundStyle(.tertiary)
            }
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            TaskOutline(tree: board.tree, roots: items.map(\.id)) { row in
                let info = board.rows[row.id]
                TaskRow(
                    task: row.task, project: row.depth == 0 ? info?.project : nil, session: info?.session.map(workspace.withLiveState),
                    delivery: info?.delivery, marks: board.children[row.id])
            }
            .padding(.horizontal, 20)
        }
    }

    private func rows(_ items: [TaskBoard.Row]) -> some View {
        ForEach(items) { row in
            TaskRow(task: row.task, project: row.project, session: row.session.map(workspace.withLiveState), delivery: row.delivery)
                .padding(.horizontal, 20)
        }
    }
}

/// 一条任务：圆圈分三态（待办空心、进行中半满、完成对勾），点它完成（完成的回到待办；还有没完成的子任务时先问，确认后一起完成），点文字整页打开；
/// 第二行写所在项目（面板里跨项目时）与交给 Pi 的会话此刻的状态，点状态在内容区打开那个会话的整页。点任务文字整页打开它。右键是 `CardActions`。
struct TaskRow: View {
    let task: Card
    /// 跨项目列着时写上所在项目；项目页里不写。
    var project: Project?
    /// 交给 Pi 的任务：那个会话此刻的状态，以及发给它的最近一条投送请求。
    var session: PiSessionState?
    var delivery: DeliveryRequest?
    /// 直接下级（子任务与挂着的灵感）；完成圈分段与子任务进度由它推出。
    var marks: [ChildMark]?
    private var subtasks: TaskProgress? { .subtasks(in: marks) }
    var compact = false
    @Environment(\.taskStructure) private var structure
    @State private var confirmsSubtasks = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var done: Bool { task.status == .done }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 8 : 10) {
            Button { toggle() } label: {
                TaskRingView(status: task.status, ring: TaskRing(marks), done: done, size: compact ? 12 : 14)
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .accessibilityLabel(done ? "回到待办" : "完成")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(task.title)
                        .font(.system(size: 13)).strikethrough(done).foregroundStyle(done ? palette.ink3 : palette.ink)
                        .lineLimit(2)
                    if !done { PromptMarkIcon(mark: PromptMark(task), showsSession: session != nil) }
                }
                .onTapGesture(perform: open)
                if project != nil || (!done && (session != nil || subtasks != nil)) { detail }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, compact ? 1 : 3)
        .frame(minHeight: compact ? 22 : 28)
        .contentShape(.rect)
        .contextMenu { CardActions(card: task) }
        // 读屏：整行一个元素"任务内容，项目，Pi 在做什么"，值是状态，默认动作切换完成（文案见 TaskSpeech）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, PromptMark(task).speech, TaskRing(marks).speech, project?.name, session.map { $0.state.presence }].compactMap { $0 }.joined(separator: "，"))
        .accessibilityValue(TaskSpeech.value(task.status))
        .accessibilityAction { toggle() }
        .accessibilityAction(named: TaskSpeech.toggle(done: done), toggle)
        .accessibilityAction(named: "打开", open)
        .accessibilityAction(named: "看 Agent 的近况") { if let session { workspace.openSession(session.sessionID) } }
        .accessibilityActions {
            if let indent = structure?.indent { Button("缩进", action: indent) }
            if let outdent = structure?.outdent { Button("反缩进", action: outdent) }
        }
        .confirmationDialog(TaskCopy.openSubtasks(subtasks), isPresented: $confirmsSubtasks) {
            Button("全部完成", action: commitToggle)
        }
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
            if let subtasks, !done {
                Text(TaskCopy.progress(subtasks)).monospacedDigit().foregroundStyle(palette.ink3)
            }
            if let session, !done {
                let shown = services.settings.shown(session, delivery: delivery)
                HStack(spacing: 4) {
                    PiStateDot(shown: shown, size: 5)
                    Text(shown.presence).foregroundStyle(shown.tint(palette))
                    PiElapsed(session: session, font: .system(size: 11))
                }
                .sessionLink(session.sessionID)
                .help("交给了 Agent 会话「\(session.title)」，点开看近况")
            }
        }
        .font(.system(size: 11))
    }

    /// 整页打开这条任务（与灵感同一个纸页）：收起任务面板。
    private func open() {
        workspace.overlay = nil
        workspace.openCard = task.id
    }

    private func toggle() {
        if !done, TaskCopy.hasOpen(subtasks) { confirmsSubtasks = true } else { commitToggle() }
    }

    private func commitToggle() {
        let task = task
        workspace.attempt { try await workspace.toggle(task) }
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
                    Button("未分类") { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 10)
                        Text(current?.name ?? "未分类").lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(palette.fill.opacity(2), in: .capsule)
                    .contentShape(.capsule)
                }
                .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("挂到 \(projects.first { $0.id == target }?.name ?? "未分类")")
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
