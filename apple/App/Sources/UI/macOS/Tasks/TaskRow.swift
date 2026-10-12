#if os(macOS)
import CueStore
import SwiftUI

/// 一条任务（项目页的任务区与任务面板同一种行）：圆圈分三态（待办空心、进行中半满、完成对勾），点它完成（完成的回到待办；
/// 还有没完成的子任务时先问，确认后一起完成）；点行的其余地方弹出任务浮层（`TaskSheet`）。标题下一行写进度（折起时连提示词条数）、
/// 所在项目（面板里跨项目时）与交给 Pi 的会话此刻的状态。展开时它的提示词一条一行列在下面（`PromptLine`），不用打开任务就看得到、点得开。
/// 顶层的行与上一组之间多留一点空，子任务的圈小一号：一眼分出哪几条是一件事。右键是 `CardActions`。
struct TaskRow: View {
    let task: Card
    var depth = 0
    /// 跨项目列着时写上所在项目；项目页里不写。
    var project: Project?
    /// 交给 Agent 的任务：同步来的会话记录（别的 Mac 上的也有）与发给它的最近一条投送请求；本机在线的会话在行里换上桥上的实时状态。
    var session: PiSessionState?
    var delivery: DeliveryRequest?
    /// 直接下级（提示词与子任务）；完成圈、提示词计数与子任务进度由它推出。
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

    /// 圈那一列多宽：提示词的行按它缩进，字与任务标题对齐。
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
    private var tally: PromptTally { PromptTally(marks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            head
            if expanded, !done {
                ForEach(prompts) { prompt in
                    PromptLine(prompt: prompt, replied: marks?.first { $0.id == prompt.id }?.isDone ?? false)
                }
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
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(depth == 0 ? Typography.body.weight(.medium) : Typography.body)
                    .strikethrough(done).foregroundStyle(done ? palette.ink3 : palette.ink)
                    .lineLimit(2)
                if let progress { Text(progress).font(Typography.meta).monospacedDigit().foregroundStyle(palette.ink3).lineLimit(1) }
                if project != nil || (!done && live != nil) { place }
            }
            Spacer(minLength: 4)
            if !done, tally.suggestsDone(task) { MarkDoneChip(action: toggle).transition(.opacity) }
        }
        .animation(Motion.quick, value: tally)
        .padding(.horizontal, Self.inset).padding(.vertical, 5)
        .frame(minHeight: TaskMetrics.rowHeight)
        .background(hovering ? palette.fill : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .contextMenu { CardActions(card: task) }
        // 读屏：整行一个元素"任务内容，进度，项目，Pi 在做什么"，值是状态，默认动作切换完成（文案见 TaskSpeech）
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([task.title, TaskSpeech.progress(marks), project?.name, live.map { services.settings.shown($0, delivery: delivery).presence }].compactMap { $0 }.joined(separator: "，"))
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

    /// 标题下的进度：展开时提示词已逐条列着，只写子任务进度（做完的子任务不列）；折起时连提示词条数一起写。
    private var progress: Dotted? {
        guard !done else { return nil }
        return expanded ? subtasks.map { Dotted(TaskCopy.progress($0)) } : TaskCopy.counts(marks)
    }

    /// 所在项目与交给 Pi 的会话此刻的状态（"Agent 正在工作 · 运行了 4 分钟"），项目名照写，挤不下时截会话状态。
    private var place: some View {
        HStack(spacing: 10) {
            if let project {
                HStack(spacing: 4) {
                    ProjectGlyph(project: project, size: 10)
                    Text(project.name).lineLimit(1)
                }
                .foregroundStyle(palette.ink3)
                .layoutPriority(2)
            }
            if let session = live, !done {
                let shown = services.settings.shown(session, delivery: delivery)
                HStack(spacing: 4) {
                    PiStateDot(shown: shown, size: 5)
                    Text(shown.presence).foregroundStyle(shown.labelTint(palette))
                    Dot().foregroundStyle(palette.ink3)
                    PiElapsed(shown: shown, font: Typography.meta)
                }
                .lineLimit(1)
                .sessionLink(session.sessionID)
                .help("交给了 Agent 会话「\(session.title)」，点开看近况")
            }
        }
        .font(Typography.meta)
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

/// 任务下的一条提示词：左边一个小标记说它此刻怎样（没交出去是空的对话框、在处理是会话状态点、已回复是实心对话框），
/// 字与任务标题对齐、一行截断；交出去过的右边写状态词。指针停上去时右边出一颗钮（交给 Agent / 再交一次 / 看会话，同 `PromptState.action`）。
/// 点行进编辑页；按住可拖到别的任务上。交出去之后下面多一行小字（`PromptProgress`）。
struct PromptLine: View {
    let prompt: Card
    let replied: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents
    @State private var hovering = false

    var body: some View {
        // 本机在线的会话换上桥上的实时状态：同步记录按节流写，会落后几秒
        let handoff = agents.items[prompt.id].map(workspace.withLiveState)
        let state = PromptState(isReplied: replied, handoff: handoff, launching: agents.launching.contains(prompt.id))
        VStack(alignment: .leading, spacing: 0) {
            row(state)
            switch state {
            case .working(let item), .replied(let item?): PromptProgress(item: item)
            default: EmptyView()
            }
        }
    }

    private func row(_ state: PromptState) -> some View {
        HStack(spacing: TaskRow.columnGap) {
            mark(state).frame(width: TaskRow.ringColumn)
            Text(prompt.title).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(1)
            Spacer(minLength: 8)
            if hovering, let action = state.action { button(action) } else { status(state) }
        }
        .padding(.horizontal, TaskRow.inset)
        .frame(minHeight: 26)
        .background(hovering ? palette.fill : .clear, in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { workspace.open(prompt) }
        .ideaDrag(prompt.id)
        .contextMenu { CardActions(card: prompt) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("提示词：\(prompt.title)")
        .accessibilityAction(named: "打开") { workspace.open(prompt) }
    }

    @ViewBuilder private func mark(_ state: PromptState) -> some View {
        switch state {
        case .unsent: Image(systemName: "text.bubble").foregroundStyle(palette.ink3)
        case .launching: Circle().strokeBorder(palette.signature, lineWidth: 1.5).frame(width: 7, height: 7)
        case .working(let item): PiStateDot(shown: services.settings.shown(item), size: 6)
        case .ended: Image(systemName: "stop.circle").foregroundStyle(palette.ink3)
        case .replied: Image(systemName: "text.bubble.fill").foregroundStyle(palette.ink2)
        }
    }

    @ViewBuilder private func status(_ state: PromptState) -> some View {
        Group {
            switch state {
            case .unsent: EmptyView()
            case .launching: Text("正在开会话").foregroundStyle(palette.ink3)
            case .working(let item):
                let shown = services.settings.shown(item)
                Text(shown.label).foregroundStyle(shown.labelTint(palette))
            case .ended: Text("已结束").foregroundStyle(palette.ink3)
            case .replied: Text("已回复").foregroundStyle(palette.ink3)
            }
        }
        .font(Typography.meta).lineLimit(1).fixedSize()
    }

    private func button(_ action: PromptAction) -> some View {
        let title: String, symbol: String
        switch action {
        case .handOff: (title, symbol) = ("交给 Agent", "paperplane")
        case .handAgain: (title, symbol) = ("再交一次", "paperplane")
        case .watch: (title, symbol) = ("看会话", "chevron.right")
        }
        return Button {
            if case .watch(let item) = action { workspace.show(.session(item.state.sessionID)) } else { workspace.handOff(prompt) }
        } label: {
            Label(title, systemImage: symbol).font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink)
                .labelStyle(.titleAndIcon).fixedSize()
        }
        .buttonStyle(PressStyle())
    }
}

/// 提示词交出去之后行下面的小字：Agent 此刻最要紧的一句（`PiRowLine`，与会话行同一来源：在做什么、问你什么、出了什么错、结果）加计时；
/// 等你确认、出错用状态色，其余是次要墨色。点它打开会话。这一行没有话可说（压缩上下文、已结束）时不画，状态词已在提示词那一行右边。
private struct PromptProgress: View {
    let item: PiSessionListItem
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = services.settings.shown(item)
        if let line = PiRowLine.of(item.state, draft: nil, end: nil, failure: shown.undelivered(item.delivery)?.failure) {
            HStack(spacing: 4) {
                Text(line.speech).foregroundStyle(shown.needsYou ? shown.labelTint(palette) : palette.ink3).lineLimit(1)
                if shown.clock != nil {
                    Dot().foregroundStyle(palette.ink3)
                    PiElapsed(shown: shown, font: Typography.meta).fixedSize()
                }
            }
            .font(Typography.meta)
            .padding(.leading, TaskRow.inset + TaskRow.ringColumn + TaskRow.columnGap).padding(.trailing, TaskRow.inset)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sessionLink(item.state.sessionID)
            .help("点开看会话「\(item.state.title)」")
        }
    }
}

/// 一行新建任务：↩ 添加，保持焦点以便连续输入。`parent` 给了时建成它的子任务（任务浮层里）；`choosesProject` 时右边可换落到哪个项目（任务面板跨项目）。
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
