#if os(macOS)
import CueStore
import SwiftUI

/// 一条任务或步骤（项目页的任务区与任务面板同一种行），一行：完成圈（`TaskCompletionRing`）、标题（面板里跨项目时后面写所在项目）、
/// 步骤进度，行尾一格"下一步"（`TaskNext`：Agent 等你确认、出错、有新回复、正在做，点了打开会话；或"写好了"，点了打开任务浮窗）。
/// 一个叶子任务一个 Agent 会话，它此刻怎样只在这一格说；要 Agent 做什么写在任务浮窗里。点行的其余地方弹出任务浮窗（`TaskSheet`）。
/// 右键是 `CardActions`。
struct TaskRow: View {
    let task: Card
    /// 跨项目列着时写上所在项目；项目页里不写。
    var project: Project?
    /// 交给 Agent 的任务：同步来的会话记录（别的 Mac 上的也有）与发给它的最近一条投送请求；本机在线的会话在行里换上桥上的实时状态。
    var session: PiSessionState?
    var delivery: DeliveryRequest?
    /// 步骤勾了几个（完成圈与进度由它推出）。
    var subtasks: TaskProgress?
    /// 写好了要 Agent 做什么、还没开始（它下面有草稿）。
    var hasDraft = false
    @Environment(\.taskStructure) private var structure
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var hovering = false

    /// 圈那一列多宽：浮窗里提示词与新建行按它缩进，字与任务标题对齐。
    static let ringColumn: CGFloat = 16
    static let columnGap: CGFloat = 10
    /// 行的内边距（悬停的淡底也在这里）。
    static let inset: CGFloat = 8

    private var done: Bool { task.status == .done }

    private var next: TaskNext? {
        guard !done else { return nil }
        let live = session.map(workspace.withLiveState)
        return TaskNext(shown: live.map { workspace.shown($0, delivery: delivery) }, sessionID: live?.sessionID, hasDraft: hasDraft)
    }

    var body: some View {
        let next = next
        HStack(alignment: .firstTextBaseline, spacing: Self.columnGap) {
            TaskCompletionRing(task: task, subtasks: subtasks, agentBusy: next.map(\.agentBusy) ?? false)
            Text(task.title)
                .font(Typography.body.weight(.medium))
                .strikethrough(done).foregroundStyle(done ? palette.ink3 : palette.ink)
                .lineLimit(1)
                .layoutPriority(1)
            if let project {
                // 挤不下时先让项目名缩，标题与进度照写
                HStack(spacing: 4) {
                    ProjectGlyph(project: project, size: 10)
                    Text(project.name).lineLimit(1)
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .layoutPriority(-1)
            }
            if !done, let subtasks {
                Text("\(subtasks.done)/\(subtasks.total)").font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3).fixedSize()
            }
            Spacer(minLength: 8)
            if let next { NextStep(next: next, task: task) }
        }
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
        .accessibilityLabel([task.title, project?.name, subtasks.map(TaskCopy.progress), next.map(NextStep.speech)].compactMap { $0 }.joined(separator: "，"))
        .accessibilityValue(TaskSpeech.value(task.status))
        .accessibilityAction(named: TaskSpeech.toggle(done: done)) { let id = task.id; workspace.attempt { try await workspace.toggle(id) } }
        .accessibilityAction(named: "打开", open)
        .accessibilityActions {
            if let indent = structure?.indent { Button("缩进", action: indent) }
            if let outdent = structure?.outdent { Button("反缩进", action: outdent) }
        }
    }

    private func open() { workspace.open(task) }

}

/// 行尾的"下一步"（`TaskNext`）：会话那边的事写状态标、状态词（等你确认、出错用状态色）与计时，点了打开会话；
/// 写好了没开始的写"写好了"，点了打开任务浮窗。都带一个 › 表示点得进去。
private struct NextStep: View {
    let next: TaskNext
    let task: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: go) {
            HStack(spacing: 5) {
                switch next {
                case .agent(let shown, _):
                    PiStateDot(shown: shown, size: 6)
                    Text(shown.label).foregroundStyle(shown.needsYou ? shown.labelTint(palette) : palette.ink2)
                    if shown.clock != nil, !shown.needsYou { PiElapsed(shown: shown, font: Typography.meta).foregroundStyle(palette.ink3) }
                case .draft:
                    Text("写好了").foregroundStyle(palette.ink2)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.ink3)
            }
            .font(Typography.meta)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8).frame(height: 22)
            .background(palette.fill, in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .help(help)
    }

    static func speech(_ next: TaskNext) -> String {
        switch next {
        case .agent(let shown, _): shown.label
        case .draft: "写好了，还没开始"
        }
    }

    private var help: String {
        switch next {
        case .agent: "打开这件事的 Agent 会话"
        case .draft: "打开任务，开始交给 Agent"
        }
    }

    private func go() {
        switch next {
        case .agent(_, let sessionID): workspace.show(.session(sessionID))
        case .draft: workspace.open(task)
        }
    }
}

/// 完成圈（任务行、任务浮窗左栏的步骤）：点它完成，完成的回到待办。还有没勾的步骤时先问一起完成；它的 Agent 还在做或在等你时先问一句——
/// 完成就是做完了，它（和它的步骤）的会话随之结束（`Workspace.toggle`）。
struct TaskCompletionRing: View {
    let task: Card
    var subtasks: TaskProgress?
    /// 它交给的会话此刻在做或在等你。
    var agentBusy = false
    var size: CGFloat = 15
    @Environment(Workspace.self) private var workspace
    @State private var confirmsSteps = false
    @State private var confirmsAgent = false

    private var done: Bool { task.status == .done }

    var body: some View {
        Button(action: tap) {
            TaskRingView(status: task.status, ring: TaskRing(subtasks), done: done, size: size).frame(width: TaskRow.ringColumn)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel(TaskSpeech.toggle(done: done))
        .sensoryFeedback(.success, trigger: task.status) { $1 == .done }
        .dialog(TaskCopy.openSubtasks(subtasks), isPresented: $confirmsSteps, buttons: [DialogButton(title: "全部完成") { commit() }])
        .dialog("Agent 还在做这件事", isPresented: $confirmsAgent, message: "完成会把它的会话一起结束。", buttons: [DialogButton(title: "完成并结束会话") { commit() }])
    }

    private func tap() {
        if done { return commit() }
        if TaskCopy.hasOpen(subtasks) { confirmsSteps = true } else if agentBusy { confirmsAgent = true } else { commit() }
    }

    private func commit() {
        let id = task.id
        workspace.attempt { try await workspace.toggle(id) }
    }
}

extension TaskNext {
    /// 会话此刻在做或在等你（完成前要先问一句）。
    var agentBusy: Bool {
        guard case .agent(let shown, _) = self else { return false }
        switch shown.status {
        case .working, .asking, .delivery: return true
        default: return false
        }
    }
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
