#if os(macOS)
import CueStore
import SwiftUI

/// 一条任务（项目页的任务区与任务面板同一种行）。一个任务一个 Agent 会话，所以 Agent 此刻在做什么只写在这里一处：
/// 第一排是完成圈（点它完成；还有没完成的子任务时先问）、标题、行尾的子任务进度；交给过 Agent 的，下面一句是那个会话此刻最要紧的话
/// （`AgentLine`：在做什么、问你什么、出了什么错，点它打开会话）；面板里跨项目时这一句前面写所在项目。
/// 展开时它的提示词一条一行列在下面（`PromptLine`，只说发没发出去）。点行的其余地方弹出任务浮窗（`TaskSheet`）。
/// 顶层的行与上一组之间多留一点空，子任务的圈小一号：一眼分出哪几条是一件事。右键是 `CardActions`。
struct TaskRow: View {
    let task: Card
    var depth = 0
    /// 跨项目列着时写上所在项目；项目页里不写。
    var project: Project?
    /// 发给 Agent 的任务：同步来的会话记录（别的 Mac 上的也有）与发给它的最近一条投送请求；本机在线的会话在行里换上桥上的实时状态。
    var session: PiSessionState?
    var delivery: DeliveryRequest?
    /// 子任务做完没有（完成圈与进度由它推出）。
    var marks: [ChildMark]?
    /// 挂在它下面的提示词，展开时逐条列出。
    var prompts: [Card] = []
    var expanded = true
    @Environment(\.taskStructure) private var structure
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var confirmsSubtasks = false
    @State private var hovering = false

    /// 圈那一列多宽：提示词与 Agent 那一句按它缩进，字与任务标题对齐。
    static let ringColumn: CGFloat = 16
    static let columnGap: CGFloat = 10
    /// 行的内边距（悬停的淡底也在这里）。
    static let inset: CGFloat = 8

    /// 行尾要不要折起箭头：有子任务或列着提示词。
    static func folds(_ row: TaskTree.Row, prompts: [UUID: [Card]]) -> Bool {
        row.childCount > 0 || !(prompts[row.id] ?? []).isEmpty
    }

    private var live: PiSessionState? { session.map(workspace.withLiveState) }
    private var done: Bool { task.status == .done }
    private var subtasks: TaskProgress? { .subtasks(in: marks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if expanded, !done {
                ForEach(prompts) { PromptLine(prompt: $0) }
            }
        }
        // 顶层的一组与上一组之间多留一点空
        .padding(.top, depth == 0 ? 8 : 0)
        .dialog(TaskCopy.openSubtasks(subtasks), isPresented: $confirmsSubtasks, buttons: [DialogButton(title: "全部完成") { commitToggle() }])
    }

    private var head: some View {
        HStack(alignment: .firstTextBaseline, spacing: Self.columnGap) {
            Button { toggle() } label: {
                TaskRingView(status: task.status, ring: TaskRing(marks), done: done, size: depth == 0 ? 15 : 13)
                    .frame(width: Self.ringColumn)
            }
            .buttonStyle(PressStyle(scale: 0.85))
            .accessibilityLabel(done ? "回到待办" : "完成")
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.title)
                        .font(depth == 0 ? Typography.body.weight(.medium) : Typography.body)
                        .strikethrough(done).foregroundStyle(done ? palette.ink3 : palette.ink)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if let progress { Text(progress).font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3) }
                }
                if project != nil || (!done && live != nil) { place }
            }
        }
        .padding(.horizontal, Self.inset).padding(.vertical, 5)
        .frame(minHeight: TaskMetrics.rowHeight)
        .background(hovering ? palette.fill : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu { CardActions(card: task) }
        // 读屏：整行一个元素"任务内容，进度，项目，Agent 在做什么"，值是状态，默认动作切换完成（文案见 TaskSpeech）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, progress?.spoken, project?.name, live.map { services.settings.shown($0, delivery: delivery).presence }].compactMap { $0 }.joined(separator: "，"))
        .accessibilityValue(TaskSpeech.value(task.status))
        .accessibilityAction { toggle() }
        .accessibilityAction(named: TaskSpeech.toggle(done: done), toggle)
        .accessibilityAction(named: "打开", open)
        .accessibilityAction(named: "看 Agent 的近况") { if let live { workspace.show(.session(live.sessionID)) } }
        .accessibilityActions {
            if let indent = structure?.indent { Button("缩进", action: indent) }
            if let outdent = structure?.outdent { Button("反缩进", action: outdent) }
        }
    }

    /// 行尾的进度：子任务做了几个（做完的子任务不列在下面）；折起时提示词也看不见了，再写它有几条。
    private var progress: Dotted? {
        guard !done else { return nil }
        return Dotted(expanded || prompts.isEmpty ? nil : "\(prompts.count) 条提示词", subtasks.map { "\($0.done)/\($0.total)" }).nonEmpty
    }

    /// 标题下一行：所在项目（跨项目时）与 Agent 此刻最要紧的一句（`AgentLine`），项目名照写，挤不下时截那一句。
    private var place: some View {
        HStack(spacing: 10) {
            if let project {
                HStack(spacing: 4) {
                    ProjectGlyph(project: project, size: 10)
                    Text(project.name).lineLimit(1)
                }
                .font(Typography.meta)
                .foregroundStyle(palette.ink3)
                .layoutPriority(2)
            }
            if let live, !done { AgentLine(session: live, delivery: delivery) }
        }
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

/// 任务交给的 Agent 此刻怎样，一句话：状态标、最要紧的那句（`PiRowLine`，与会话行同一来源：在做什么、问你什么、出了什么错、结果；
/// 没话可说时是状态词）与计时。等你确认、出错用状态色，其余是次要墨色。点它打开会话。
private struct AgentLine: View {
    let session: PiSessionState
    let delivery: DeliveryRequest?
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = services.settings.shown(session, delivery: delivery)
        let line = PiRowLine.of(session, draft: nil, end: nil, failure: shown.undelivered(delivery)?.failure)
        HStack(spacing: 5) {
            PiStateDot(shown: shown, size: 5)
            Text(line?.speech ?? shown.presence)
                .foregroundStyle(shown.needsYou ? shown.labelTint(palette) : palette.ink2)
                .lineLimit(1)
            if shown.clock != nil {
                Dot().foregroundStyle(palette.ink3)
                PiElapsed(shown: shown, font: Typography.meta).fixedSize()
            }
        }
        .font(Typography.meta)
        .sessionLink(session.sessionID)
        .help("发给了 Agent 会话「\(session.title)」，点开看")
    }
}

/// 任务下的一条提示词：只说这句话发没发出去（`PromptDelivery`），Agent 在做什么写在任务那一行。左边一个小标记——没发是空的对话框、
/// 发送中是一个圈、没送到是带叹号的对话框、已发是实心的；字与任务标题对齐、一行截断；右边写"发送中""没送到""已发"。
/// 指针停上去时没发的给"发给 Agent"、没送到的给"重发"。点行在任务浮窗里编辑它（正在编辑的那条垫选中色）；按住可拖到别的任务上。
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
            Text(prompt.title).font(Typography.secondary).foregroundStyle(delivery == .sent ? palette.ink3 : palette.ink2).lineLimit(1)
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
        case .sent: Image(systemName: "text.bubble.fill").foregroundStyle(palette.ink3)
        }
    }

    @ViewBuilder private func status(_ delivery: PromptDelivery) -> some View {
        Group {
            switch delivery {
            case .unsent: EmptyView()
            case .sending: Text("发送中").foregroundStyle(palette.ink3)
            case .failed(let reason): Text("没送到").foregroundStyle(palette.failure).help(reason)
            case .sent: Text("已发").foregroundStyle(palette.ink3)
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

/// 一行新建任务：↩ 添加，保持焦点以便连续输入。`parent` 给了时建成它的子任务（任务浮窗里）；`choosesProject` 时右边可换落到哪个项目（任务面板跨项目）。
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
    private var prompt: String { parent == nil ? "添加任务" : "添加子任务" }

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
