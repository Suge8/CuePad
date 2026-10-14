#if os(macOS)
import CueStore
import SwiftUI

/// 一条任务或步骤（项目页的任务区与任务面板同一种行），一行：完成圈（`TaskCheckButton`）、标题，行尾依次是步骤进度、
/// 所在项目的图标（面板里跨项目时；悬停写全名）与那一格"下一步"（`TaskNextChip`：Agent 要你看的、正在做的，或"开始"）。
/// 一个叶子任务一个 Agent 会话，它此刻怎样只在这一格说；要 Agent 做什么写在任务浮窗里。点行的其余地方弹出任务浮窗（`TaskSheet`）。
/// 右键是 `CardActions`。
struct TaskRow: View {
    let task: Card
    /// 跨项目列着时给出所在项目（行尾画它的图标）；项目页里不给。
    var project: Project?
    /// 步骤勾了几个（完成圈与进度由它推出）。
    var subtasks: TaskProgress?
    /// 写好了要 Agent 做什么、还没交出去的草稿（行尾的"开始"）。
    var draft: Card?
    @Environment(\.taskStructure) private var structure
    @Environment(\.cardAgents) private var agents
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var check = TaskCheck()

    /// 圈那一列多宽：浮窗里提示词与新建行按它缩进，字与任务标题对齐。
    static let ringColumn: CGFloat = 16
    static let columnGap: CGFloat = 10
    /// 行的内边距（悬停的淡底也在这里）。
    static let inset: CGFloat = 8

    var body: some View {
        let next = workspace.next(for: task, agent: agents.items[task.id], draft: draft)
        let done = check.done(task)
        HStack(alignment: .firstTextBaseline, spacing: Self.columnGap) {
            TaskCheckButton(
                task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false, size: 15,
                target: CGSize(width: Self.ringColumn, height: 15), check: $check, rowTap: open)
            Text(task.title)
                .font(Typography.body.weight(.medium))
                .strikethrough(done, color: palette.ink3).foregroundStyle(done ? palette.ink3 : palette.ink)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if !done, let subtasks {
                Text("\(subtasks.done)/\(subtasks.total)").font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3).fixedSize()
            }
            if let project {
                ProjectGlyph(project: project, size: 11).help(project.name).accessibilityHidden(true)
            }
            if let next, !done { TaskNextChip(next: next) }
        }
        .animation(Motion.quick, value: done)
        .padding(.horizontal, Self.inset)
        .frame(minHeight: TaskMetrics.rowHeight)
        .background(hovering ? palette.fill : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu { CardActions(card: task, leaf: subtasks == nil) }
        .padding(.vertical, 2)
        // 读屏：整行一个元素"任务内容，项目，步骤进度，下一步"，值是状态，默认动作切换完成（文案见 TaskSpeech）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, project?.name, subtasks.map(TaskCopy.progress), next?.speech].compactMap { $0 }.joined(separator: "，"))
        .accessibilityValue(TaskSpeech.value(done ? .done : task.status))
        .accessibilityAction(named: check.phase == .pending ? "撤销完成" : TaskSpeech.toggle(done: done)) {
            workspace.tap($check, task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false)
        }
        .accessibilityAction(named: "打开", open)
        .accessibilityActions {
            if case .start(let draft) = next { Button("开始") { workspace.handOff(draft) } }
            if let indent = structure?.indent { Button("缩进", action: indent) }
            if let outdent = structure?.outdent { Button("反缩进", action: outdent) }
        }
    }

    private func open() { workspace.open(task) }
}

/// 一行新建任务：↩ 添加，保持焦点以便连续输入。`parent` 给了时建成它的一个步骤（任务浮窗里）；`choosesProject` 时右边可换落到哪个项目（任务面板跨项目）。
struct NewTaskField: View {
    let project: UUID?
    var parent: UUID?
    var choosesProject = false
    /// 出现时光标就在这一行（任务面板：从"新建任务"打开后直接写）。
    var autofocus = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosen: UUID??
    @FocusState private var focused: Bool

    private var target: UUID? { chosen ?? project }
    private var prompt: String { parent == nil ? "添加任务" : "添加步骤" }

    var body: some View {
        HStack(spacing: TaskRow.columnGap) {
            // 入口不用系统占位灰：那样看起来像不能点
            Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink2).accessibilityHidden(true)
                .frame(width: TaskRow.ringColumn)
            TextField(text: $text, prompt: Text(prompt).foregroundStyle(palette.ink2)) { Text(prompt) }.textFieldStyle(.plain).font(Typography.body)
                .accessibilityLabel(prompt)
                .focused($focused)
                .onSubmit(add)
            if choosesProject, let projects = workspace.catalog?.projects, !projects.isEmpty {
                Menu {
                    Button(CaptureCopy.unfiled) { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 10)
                        Text(current?.name ?? CaptureCopy.unfiled).lineLimit(1)
                    }
                    .font(Typography.meta).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 8).frame(height: 24)
                    .background(palette.fill.opacity(2), in: .capsule)
                    .contentShape(.capsule)
                }
                .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("挂到 \(projects.first { $0.id == target }?.name ?? CaptureCopy.unfiled)")
            }
        }
        .padding(.horizontal, TaskRow.inset)
        .frame(minHeight: TaskMetrics.rowHeight)
        .onAppear { focused = autofocus }
    }

    private func add() {
        let content = text.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        text = ""
        if let parent {
            let store = workspace.services.store
            workspace.attempt { _ = try await store.createTask(content, under: parent) }
        } else {
            let project = target
            workspace.attempt { _ = try await workspace.createTask(content, in: project) }
        }
    }
}

#endif
