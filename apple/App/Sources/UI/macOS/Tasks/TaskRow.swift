#if os(macOS)
import CueStore
import SwiftUI

/// 一条任务（项目页的任务区与任务面板同一种行），一行：完成圈（点它完成；还有没勾的步骤时先问）、标题（面板里跨项目时后面写所在项目）、
/// 步骤进度，行尾一格"下一步"（`TaskNext`：Agent 等你确认、出错、有新回复、正在做，点了打开会话；或"待发 N 条"，点了打开任务浮窗）。
/// 一个任务一个 Agent 会话，它此刻怎样只在这一格说；提示词不列在这里，在任务浮窗里。点行的其余地方弹出任务浮窗（`TaskSheet`）。
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
    /// 写了还没发的提示词有几条（送达的就用掉了，不算）。
    var pending = 0
    @Environment(\.taskStructure) private var structure
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var confirmsSubtasks = false
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
        return TaskNext(shown: live.map { services.settings.shown($0, delivery: delivery) }, sessionID: live?.sessionID, pending: pending)
    }

    var body: some View {
        let next = next
        HStack(alignment: .firstTextBaseline, spacing: Self.columnGap) {
            Button { toggle() } label: {
                TaskRingView(status: task.status, ring: TaskRing(subtasks), done: done, size: 15)
                    .frame(width: Self.ringColumn)
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .accessibilityLabel(done ? "回到待办" : "完成")
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
        .contextMenu { CardActions(card: task) }
        .padding(.vertical, 2)
        // 读屏：整行一个元素"任务内容，项目，步骤进度，下一步"，值是状态，默认动作切换完成（文案见 TaskSpeech）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, project?.name, subtasks.map(TaskCopy.progress), next.map(NextStep.speech)].compactMap { $0 }.joined(separator: "，"))
        .accessibilityValue(TaskSpeech.value(task.status))
        .accessibilityAction { toggle() }
        .accessibilityAction(named: TaskSpeech.toggle(done: done), toggle)
        .accessibilityAction(named: "打开", open)
        .accessibilityActions {
            if let indent = structure?.indent { Button("缩进", action: indent) }
            if let outdent = structure?.outdent { Button("反缩进", action: outdent) }
        }
        .dialog(TaskCopy.openSubtasks(subtasks), isPresented: $confirmsSubtasks, buttons: [DialogButton(title: "全部完成") { commitToggle() }])
    }

    private func open() { workspace.open(task) }

    private func toggle() {
        if !done, TaskCopy.hasOpen(subtasks) { confirmsSubtasks = true } else { commitToggle() }
    }

    private func commitToggle() {
        let task = task
        workspace.attempt { try await workspace.toggle(task.id) }
    }
}

/// 行尾的"下一步"（`TaskNext`）：会话那边的事写状态标、状态词（等你确认、出错用状态色）与计时，点了打开会话；
/// 待发的写"待发 N 条"，点了打开任务浮窗（停在第一条没发的上面）。都带一个 › 表示点得进去。
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
                case .pending(let count):
                    Text("待发 \(count) 条").foregroundStyle(palette.ink2)
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
        case .pending(let count): "待发 \(count) 条提示词"
        }
    }

    private var help: String {
        switch next {
        case .agent: "打开这件事的 Agent 会话"
        case .pending: "打开任务，把写好的提示词发给 Agent"
        }
    }

    private func go() {
        switch next {
        case .agent(_, let sessionID): workspace.show(.session(sessionID))
        case .pending: workspace.open(task)
        }
    }
}

/// 任务浮窗左栏的一条提示词：只说这句话发没发出去（`PromptDelivery`；送达就用掉了，不在这里）。左边一个小标记——没发是空的对话框、
/// 发送中是一个圈、没送到是带叹号的对话框；右边写"发送中""没送到"。指针停上去时没发的给"发给 Agent"、没送到的给"重发"。
/// 点行在右栏编辑它（正在编辑的那条垫选中色）；按住可拖到别的任务上。
struct PromptLine: View {
    let prompt: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents
    @State private var hovering = false

    var body: some View {
        let delivery = PromptDelivery(prompt.id, agents: agents)
        HStack(spacing: TaskRow.columnGap) {
            mark(delivery).frame(width: TaskRow.ringColumn)
            Text(prompt.title).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(1)
            Spacer(minLength: 8)
            if hovering, delivery.canSend { send(delivery) } else { status(delivery) }
        }
        .padding(.horizontal, TaskRow.inset)
        .frame(minHeight: 26)
        .background(workspace.openTask?.prompt == prompt.id ? palette.selection : hovering ? palette.fill : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { workspace.open(prompt) }
        .ideaDrag(prompt.id)
        .contextMenu { CardActions(card: prompt) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("提示词：\(prompt.title)")
        .accessibilityAction(named: "打开") { workspace.open(prompt) }
    }

    @ViewBuilder private func mark(_ delivery: PromptDelivery) -> some View {
        switch delivery {
        case .unsent: Image(systemName: "text.bubble").foregroundStyle(palette.ink3)
        case .sending: Circle().strokeBorder(palette.signature, lineWidth: 1.5).frame(width: 7, height: 7)
        case .failed: Image(systemName: "exclamationmark.bubble").foregroundStyle(palette.failure)
        }
    }

    @ViewBuilder private func status(_ delivery: PromptDelivery) -> some View {
        Group {
            switch delivery {
            case .unsent: EmptyView()
            case .sending: Text("发送中").foregroundStyle(palette.ink3)
            case .failed(let reason): Text("没送到").foregroundStyle(palette.failure).help(reason)
            }
        }
        .font(Typography.meta).lineLimit(1).fixedSize()
    }

    private func send(_ delivery: PromptDelivery) -> some View {
        Button { workspace.handOff(prompt) } label: {
            Label(delivery == .unsent ? "发给 Agent" : "重发", systemImage: "paperplane")
                .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink)
                .labelStyle(.titleAndIcon).fixedSize()
        }
        .buttonStyle(PressStyle())
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
