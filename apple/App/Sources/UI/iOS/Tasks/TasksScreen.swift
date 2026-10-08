#if os(iOS)
import CueStore
import SwiftUI

/// 任务页（书架上的"任务"一行、iPad 侧栏、项目页"还有 N 条"进入）：顶上常驻一行快速添加（↩ 即一条，落当前项目或未分类，可换）；下面按 进行中 / 待办 / 最近完成（折起）分组，跨项目，
/// 子任务缩进跟在上级下（`TaskOutline`：长按拖动排序、拖到一条上成为它的子任务、右滑缩进左滑反缩进），顶层写所在项目，交给 Pi 的写那个会话此刻在做什么。
/// 点圆圈完成（完成的点了回到待办），点文字在浮窗里打开（`TaskSheet`），长按是 `CardActions`。
struct TasksScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var board: TaskBoard?
    @State private var showsCompleted = false
    @Environment(Navigation.self) private var navigation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let board { content(board) }
            }
            #if DEBUG
            .onChange(of: board?.done.last?.id) {
                if DebugScene.defaults.bool(forKey: "CuePadShowsDone"), let last = board?.done.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            #endif
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            NewTaskLine(project: workspace.currentProject, projects: workspace.catalog?.projects)
                .padding(.horizontal, 6)
                .background(palette.paper, in: .rect(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .floatingHeader("任务", detail: board?.counts.summary ?? "")
        #if DEBUG
        .onAppear { if DebugScene.defaults.bool(forKey: "CuePadShowsDone") { showsCompleted = true } }
        #endif
        .animation(.easeOut(duration: 0.2), value: board.map { [$0.inProgress, $0.todo, $0.done].flatMap { $0.map(\.id) } })
        .observing(services.store, TaskBoard.tables, into: $board, onError: workspace.fail) {
            try TaskBoard.read(from: $0)
        }
    }

    private func content(_ board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if board.inProgress.isEmpty && board.todo.isEmpty {
                Text(board.done.isEmpty ? "还没有任务，在上面写一条" : "全部完成了").foregroundStyle(palette.ink2)
                    .padding(.horizontal, 4).padding(.top, 8)
            }
            group("进行中", board.inProgress, count: board.counts.inProgress, in: board)
            group("待办", board.todo, count: board.counts.todo, in: board)
            if !board.done.isEmpty { completed(board.done) }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
    }

    @ViewBuilder private func group(_ title: String, _ roots: [TaskBoard.Row], count: Int, in board: TaskBoard) -> some View {
        if !roots.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header(title, count: count)
                TaskOutline(tree: board.tree, roots: roots.map(\.id)) { row in
                    let info = board.rows[row.id]
                    line(
                        row.task, project: row.depth == 0 ? info?.project : nil, session: info?.session, delivery: info?.delivery,
                        marks: board.children[row.id])
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(palette.paper, in: .rect(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").foregroundStyle(palette.ink3)
        }
        .font(.footnote.weight(.semibold)).foregroundStyle(palette.ink2)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func completed(_ rows: [TaskBoard.Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(Motion.quick) { showsCompleted.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("最近完成 \(rows.count)")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsCompleted ? 90 : 0)).accessibilityHidden(true)
                        Spacer()
                    }
                    .font(.footnote.weight(.semibold)).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsCompleted ? "已展开" : "已折叠")
                // 做完的一键收走：归档后不占列表，照样搜得到
                Button("全部归档", systemImage: "archivebox") { workspace.attempt { try await workspace.archiveCompletedTasks() } }
                    .font(.footnote.weight(.semibold)).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 4).frame(minHeight: 44).contentShape(.rect)
                    .buttonStyle(.plain)
            }
            if showsCompleted {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { line($0.task, project: $0.project, session: $0.session, delivery: $0.delivery, marks: nil).id($0.id) }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(palette.paper, in: .rect(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func line(_ task: Card, project: Project?, session: PiSessionState?, delivery: DeliveryRequest?, marks: [ChildMark]?) -> some View {
        TaskLine(task: task, project: project, session: session, delivery: delivery, marks: marks)
            .contextMenu { CardActions(card: task) }
    }
}

/// 一条任务：圆圈分三态（待办空心、进行中半满、完成对勾），点文字在浮窗里打开。点圆圈立即显示完成（对勾、删除线、成功触感），停留片刻再从列表移出；
/// 这段时间里再点一下就撤销。还有没完成的子任务时先问一句，确认后连子任务一起完成。已完成的任务点一下立即回到待办。
struct TaskLine: View {
    let task: Card
    /// 任务页跨项目列着，写上所在项目；项目页里不写。
    var project: Project?
    /// 交给 Pi 的任务：那个会话此刻在做什么（点它看近况），以及发给它的最近一条投送请求。
    var session: PiSessionState?
    var delivery: DeliveryRequest?
    /// 直接下级（提示词与子任务）；完成圈分段、提示词计数与子任务进度由它推出。
    var marks: [ChildMark]?
    private var subtasks: TaskProgress? { .subtasks(in: marks) }
    private var tally: PromptTally { PromptTally(marks) }
    @Environment(\.taskStructure) private var structure
    @State private var confirmsSubtasks = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    private enum Phase { case idle, pending, committed }
    /// pending：已显示完成、还没写入；committed：已写入，等列表把它移走。
    @State private var phase = Phase.idle

    /// 完成后停留多久再移出：够看清对勾、来得及反悔。
    private static let linger: Duration = .milliseconds(900)

    private var done: Bool { task.status == .done || phase != .idle }

    var body: some View {
        line
            // 读屏把一行当一个元素："任务内容，未完成"（文案见 TaskSpeech）；双击即勾选（与圆圈同一个动作），长按菜单照常可用
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([task.title, tally.text, TaskRing(marks).speech, project?.name, session.map { $0.state.presence }].compactMap { $0 }.joined(separator: "，"))
            .accessibilityValue(phase == .idle ? TaskSpeech.value(task.status) : TaskSpeech.value(.done))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint)
            .accessibilityAction { tap() }
            .accessibilityActions {
                Button("打开") { navigation.openTask(task.id) }
                if let session { Button("看 Agent 的近况") { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } }
                if let indent = structure?.indent { Button("缩进", action: indent) }
                if let outdent = structure?.outdent { Button("反缩进", action: outdent) }
            }
            .confirmationDialog(
                TaskCopy.openSubtasks(subtasks), isPresented: $confirmsSubtasks, titleVisibility: .visible
            ) {
                Button("全部完成") { phase = .pending }
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

    private var hint: String {
        if phase == .pending { return "撤销完成" }
        return TaskSpeech.toggle(done: done)
    }

    private var line: some View {
        HStack(spacing: 2) {
            Button(action: tap) {
                TaskRingView(status: task.status, ring: TaskRing(marks), done: done, size: 20)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: phase) { $0 == .idle && $1 == .pending }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title.textGlyphs)
                    .font(.body).strikethrough(done)
                    .foregroundStyle(done ? palette.ink3 : palette.ink)
                    .lineLimit(2)
                if hasDetail { detail }
            }
            .padding(.vertical, hasDetail ? 6 : 0)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { navigation.openTask(task.id) }
            if !done, tally.suggestsDone(task) { MarkDoneChip(action: tap).transition(.opacity) }
        }
        .animation(Motion.quick, value: tally)
    }

    private var hasDetail: Bool { project != nil || (!done && (session != nil || counts != nil)) }

    /// "3 条提示词 · 1 已回复 · 子任务 1/2"。
    private var counts: String? { [tally.text, subtasks.map(TaskCopy.progress)].compactMap { $0 }.joined(separator: " · ").nonEmpty }

    /// 第二行：提示词计数、子任务进度、所在项目、交给的会话此刻的状态（"正在工作 · 已运行 4:02"）。
    private var detail: some View {
        HStack(spacing: 10) {
            // 计数不截；放不下时先截项目名，再截会话状态
            if !done, let counts = counts { Text(counts).monospacedDigit().foregroundStyle(palette.ink3).fixedSize() }
            if let project {
                HStack(spacing: 4) {
                    ProjectGlyph(project: project, size: 10)
                    Text(project.name)
                }
                .foregroundStyle(palette.ink3)
                .layoutPriority(-1)
            }
            if let session, !done {
                Button { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) } label: {
                    let shown = services.settings.shown(session, delivery: delivery)
                    // 放不下时先省掉用时，再只留状态点
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 4) {
                            PiStateDot(shown: shown, size: 6)
                            Text(shown.presence).foregroundStyle(shown.tint(palette))
                            PiElapsed(session: session, font: .caption)
                        }
                        HStack(spacing: 4) {
                            PiStateDot(shown: shown, size: 6)
                            Text(shown.presence).foregroundStyle(shown.tint(palette))
                        }
                        PiStateDot(shown: shown, size: 6).accessibilityLabel(shown.presence)
                    }
                }
                .layoutPriority(-0.5)
                .buttonStyle(.plain)
                .accessibilityHint("看 Agent 的近况")
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func tap() {
        switch (task.status == .done, phase) {
        case (true, _): workspace.attempt { try await workspace.toggle(task) }
        case (false, .idle): if TaskCopy.hasOpen(subtasks) { confirmsSubtasks = true } else { phase = .pending }
        case (false, .pending): phase = .idle
        case (false, .committed): break
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
                .accessibilityLabel("添加任务")
                .frame(minHeight: 44)
                .contentShape(.rect)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
            if let projects, !projects.isEmpty {
                Menu {
                    Button("未分类") { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 11)
                        Text(current?.name ?? "未分类").lineLimit(1)
                    }
                    .font(.footnote).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(palette.fill, in: .capsule)
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .accessibilityLabel("挂到 \(projects.first { $0.id == target }?.name ?? "未分类")")
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
