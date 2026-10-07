#if os(iOS)
import CueStore
import SwiftUI

/// 任务页（书架上的"任务"一行、iPad 侧栏、项目页"还有 N 条"进入）：顶上常驻一行快速添加（↩ 即一条，落当前项目或未归档，可换）；下面按 进行中 / 待办 / 最近完成（折起）分组，跨项目，
/// 子任务缩进跟在上级下（`TaskOutline`：长按拖动排序、拖到一条上成为它的子任务、右滑缩进左滑反缩进），顶层写所在项目，交给 Pi 的写那个会话此刻在做什么。
/// 点圆圈完成（完成的点了回到待办），长按是编辑、缩进、开始、交给 Pi、移到项目、删除。
struct TasksScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var board: TaskBoard?
    @State private var showsCompleted = false
    @State private var editing: CueTask?

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
        .navigationTitle("任务")
        .sheet(item: $editing) { TaskEditSheet(task: $0) }
        #if DEBUG
        .onAppear { if DebugScene.defaults.bool(forKey: "CuePadShowsDone") { showsCompleted = true } }
        .onChange(of: board?.todo.first?.id) { if DebugScene.scene == "taskedit", editing == nil { editing = board?.todo.first?.task } }
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
            group("进行中", board.inProgress, in: board)
            group("待办", board.todo, in: board)
            if !board.done.isEmpty { completed(board.done) }
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
    }

    @ViewBuilder private func group(_ title: String, _ roots: [TaskBoard.Row], in board: TaskBoard) -> some View {
        if !roots.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header(title, count: roots.count)
                TaskOutline(tree: board.tree, roots: roots.map(\.id)) { row in
                    let info = board.rows[row.id]
                    line(
                        row.task, project: row.depth == 0 ? info?.project : nil, session: info?.session, delivery: info?.delivery,
                        subtasks: board.subtasks[row.id])
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
            if showsCompleted {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { line($0.task, project: $0.project, session: $0.session, delivery: $0.delivery, subtasks: nil).id($0.id) }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(palette.paper, in: .rect(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func line(_ task: CueTask, project: Project?, session: PiSessionState?, delivery: DeliveryRequest?, subtasks: TaskProgress?) -> some View {
        TaskLine(task: task, project: project, session: session, delivery: delivery, subtasks: subtasks)
            .contextMenu { TaskActions(task: task) { editing = task } }
    }
}

/// 一条任务：圆圈分三态（待办空心、进行中半满、完成对勾）。点圆圈立即显示完成（对勾、删除线、成功触感），停留片刻再从列表移出；
/// 这段时间里再点一下就撤销。还有没完成的子任务时先问一句，确认后连子任务一起完成。已完成的任务点一下立即回到待办。
struct TaskLine: View {
    let task: CueTask
    /// 任务页跨项目列着，写上所在项目；项目页里不写。
    var project: Project?
    /// 交给 Pi 的任务：那个会话此刻在做什么（点它看近况），以及发给它的最近一条投送请求。
    var session: PiSessionState?
    var delivery: DeliveryRequest?
    /// 直接子任务的完成数与总数（没有子任务时为 nil）。
    var subtasks: TaskProgress?
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
            .accessibilityLabel([task.content, project?.name, session.map { $0.state.presence }].compactMap { $0 }.joined(separator: "，"))
            .accessibilityValue(phase == .idle ? TaskSpeech.value(task.status) : TaskSpeech.value(.done))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint)
            .accessibilityAction { tap() }
            .accessibilityActions {
                if let session { Button("看 Pi 的近况") { navigation.push(.session(session.id, seed: session)) } }
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
                Image(systemName: done ? "checkmark.circle.fill" : task.status == .inProgress ? "circle.lefthalf.filled" : "circle")
                    .foregroundStyle(done ? palette.accent : task.status == .inProgress ? palette.ink2 : palette.ink3)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .sensoryFeedback(.success, trigger: phase) { $0 == .idle && $1 == .pending }
            VStack(alignment: .leading, spacing: 3) {
                Text(task.content.textGlyphs)
                    .font(.body).strikethrough(done)
                    .foregroundStyle(done ? palette.ink3 : palette.ink)
                    .lineLimit(2)
                if hasDetail { detail }
            }
            .padding(.vertical, hasDetail ? 6 : 0)
        }
    }

    private var hasDetail: Bool { project != nil || (!done && (session != nil || subtasks != nil)) }

    /// 第二行：所在项目、子任务进度、交给 Pi 的会话此刻的状态（"Pi 正在工作 · 已运行 4:02"）。
    private var detail: some View {
        HStack(spacing: 10) {
            if let subtasks, !done {
                Text(TaskCopy.progress(subtasks)).monospacedDigit().foregroundStyle(palette.ink3).fixedSize()
            }
            if let project {
                // 一行放不下时先截项目名，进度与会话状态不截
                HStack(spacing: 4) {
                    ProjectGlyph(project: project, size: 10)
                    Text(project.name)
                }
                .foregroundStyle(palette.ink3)
                .layoutPriority(-1)
            }
            if let session, !done {
                Button { navigation.push(.session(session.id, seed: session)) } label: {
                    let shown = services.settings.shown(session, delivery: delivery)
                    HStack(spacing: 4) {
                        PiStateDot(shown: shown, size: 6)
                        Text(shown.presence).foregroundStyle(shown.tint(palette))
                        PiElapsed(session: session, font: .caption)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .accessibilityHint("看 Pi 的近况")
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
                    Button("未归档") { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    let current = projects.first { $0.id == target }
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 11)
                        Text(current?.name ?? "未归档").lineLimit(1)
                    }
                    .font(.footnote).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 10).frame(minHeight: 30)
                    .background(palette.fill, in: .capsule)
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .accessibilityLabel("挂到 \(projects.first { $0.id == target }?.name ?? "未归档")")
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
