#if os(iOS)
import CueStore
import SwiftUI

/// 任务页（书架上的"任务"一行、iPad 侧栏进入）：列表顶上一行快速添加（↩ 即一条，落当前项目或未分类，可换），
/// 跟着列表一起滚走——它是一张纸、不是玻璃，钉在顶栏下会把滚过去的列表切成上下两截；回到顶就能看到；下面按 进行中 / 待办 / 最近完成（折起）分组，跨项目，
/// 步骤缩进跟在上级下（`TaskOutline`：长按拖动排序、拖到一条上成为它的步骤；轻扫见 `CardMenu.swipes`），顶层写所在项目，行尾一格"下一步"（同 Mac 的任务行，`TaskNext`）。
/// 点圆圈完成（完成的点了回到待办），点文字推入任务的纸页（`TaskPage`），长按是 `CardActions`。
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
            .onChange(of: board?.done.last?.id) {
                if DebugHooks.preset.showsDone, let last = board?.done.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .floatingHeader("任务", detail: board?.counts.summary ?? "")
        .onAppear { if DebugHooks.preset.showsDone { showsCompleted = true } }
        .animation(.easeOut(duration: 0.2), value: board?.order)
        .observing(services.store, into: $board, onError: workspace.fail) {
            try TaskBoard.read(from: $0)
        }
    }

    private func content(_ board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            NewTaskLine(project: navigation.currentProject, projects: workspace.catalog?.projects)
                .padding(.horizontal, 6)
                .background(palette.paper, in: .rect(cornerRadius: 16, style: .continuous))
            if board.inProgress.isEmpty && board.todo.isEmpty {
                Text(board.done.isEmpty ? "还没有任务，在上面写一条" : "全部完成了").foregroundStyle(palette.ink2)
                    .padding(.horizontal, 4).padding(.top, 8)
            }
            group("进行中", board.inProgress, count: board.counts.inProgress, in: board)
            group("待办", board.todo, count: board.counts.todo, in: board)
            if !board.done.isEmpty { completed(board.done, count: board.counts.done) }
        }
        .padding(.horizontal, 16).padding(.bottom, 24)
    }

    @ViewBuilder private func group(_ title: String, _ roots: [TaskBoard.Row], count: Int, in board: TaskBoard) -> some View {
        if !roots.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header(title, count: count)
                TaskOutline(tree: board.tree, roots: roots.map(\.id)) { row in
                    TaskLine(
                        task: row.task, project: row.depth == 0 ? board.rows[row.id]?.project : nil,
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

    private func completed(_ rows: [TaskBoard.Row], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button {
                    withAnimation(Motion.quick) { showsCompleted.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("最近完成 \(count)")
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
                Button("全部归档") { workspace.attempt { try await workspace.archiveCompletedTasks() } }
                    .font(.footnote).foregroundStyle(palette.ink3)
                    .padding(.horizontal, 4).frame(minHeight: 44).contentShape(.rect)
                    .buttonStyle(.plain)
            }
            if showsCompleted {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { TaskLine(task: $0.task, project: $0.project).id($0.id) }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(palette.paper, in: .rect(cornerRadius: 16, style: .continuous))
            }
        }
    }
}

/// 一条任务：完成圈（`TaskCheckButton`：点了立即显示完成、停留片刻再移出，这段时间里再点一下撤销）、标题（点了推入任务页），
/// 标题下一行写所在项目与步骤进度；那一格"下一步"（`TaskNextChip`：Agent 要你看的、正在做的，或"开始"）与 Mac 的任务行同一个判断：
/// 手机上在行尾（屏窄，行尾就在眼前），iPad 的宽栏里紧跟标题（同 Mac：放在行尾时离标题太远，一眼看不到）。
struct TaskLine: View {
    let task: Card
    /// 任务页跨项目列着，写上所在项目；项目页里不写。
    var project: Project?
    /// 步骤进度：元信息一行与完成圈由它推出（有它的不是叶子，不给"开始"）。
    var subtasks: TaskProgress?
    @State private var check = TaskCheck()
    /// 行宽：只给长按提起的预览用（与原来的行同宽），不回写影响这一行自己的排版。
    @State private var width: CGFloat = 0
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.cardAgents) private var agents
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// 长按提起的那块纸的圆角：与列表那张纸同一个圆角。
    private static let liftRadius: CGFloat = 16

    var body: some View {
        let next = workspace.next(for: task, in: agents, steps: subtasks)
        let done = check.done(task)
        line(next: next, done: done)
            // 长按提起的是一张纸：预览是同一行垫一块纸色圆角底、与原来的行同宽。不给行本身垫底——行放在纸上，
            // 纸面上沿有一层提亮，同色的底在那里会显出一块块的方框
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            // 预览的外形也要说给系统：不说时它按自己的默认把预览裁成两端全圆
            .contentShape(.contextMenuPreview, .rect(cornerRadius: Self.liftRadius, style: .continuous))
            .contextMenu { CardActions(card: task) } lifting: {
                line(next: next, done: done, lifted: true).frame(width: width).background(palette.paper, in: .rect(cornerRadius: Self.liftRadius, style: .continuous))
            }
            // 读屏把一行当一个元素："任务内容，步骤，项目，下一步"（文案见 TaskSpeech）；双击即勾选（与圆圈同一个动作），长按菜单照常可用
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([task.title, subtasks.map(TaskCopy.progress), project?.name, next?.speech].compactMap { $0 }.joined(separator: "，"))
            .accessibilityValue(TaskSpeech.value(done ? .done : task.status))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(check.phase == .pending ? "撤销完成" : TaskSpeech.toggle(done: done))
            .accessibilityAction { workspace.tap($check, task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false) }
            .accessibilityActions {
                Button("打开") { navigation.push(.card(task.id)) }
                switch next {
                case .start(let leaf): Button("开始") { navigation.handToAgent(leaf) }
                case .agent(_, let session): Button("看 Agent 的近况") { navigation.openSession(session.id, sessionID: session.sessionID, store: services.store) }
                case nil: EmptyView()
                }
            }
    }

    /// `lifted`：长按浮起的预览。圈画成静止的：预览里再放一颗完成圈，就多一份停留与写入，勾了没到写入就长按，两颗各写一次会把完成又切回去。
    private func line(next: TaskNext?, done: Bool, lifted: Bool = false) -> some View {
        // 圈与右边那一格都对着标题第一行（`TaskRingView` 的基线），行再高也不落到中间
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            if lifted {
                TaskRingView(status: task.status, ring: TaskRing(subtasks), done: done, size: 20).frame(width: 44, height: 44)
            } else {
                TaskCheckButton(
                    task: task, subtasks: subtasks, agentBusy: next?.agentBusy ?? false, size: 20,
                    target: CGSize(width: 44, height: 44), check: $check)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(task.title.textGlyphs)
                        .font(.body).strikethrough(done, color: palette.ink3)
                        .foregroundStyle(done ? palette.ink3 : palette.ink)
                        .lineLimit(2)
                    if inline, let next, !done { TaskNextChip(next: next).transition(.opacity) }
                }
                if hasMeta(done: done) { meta(done: done) }
            }
            .padding(.vertical, hasMeta(done: done) ? 6 : 0)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture { navigation.push(.card(task.id)) }
            if !inline, let next, !done { TaskNextChip(next: next).padding(.leading, 6).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.12), value: done)
    }

    /// 宽栏（iPad）里"下一步"紧跟标题。
    private var inline: Bool { sizeClass == .regular }

    private func hasMeta(done: Bool) -> Bool { project != nil || (!done && subtasks != nil) }

    /// 标题下一行：所在项目与步骤进度（做完了不写进度）。
    private func meta(done: Bool) -> some View {
        HStack(spacing: 6) {
            if let project {
                HStack(spacing: 4) {
                    ProjectGlyph(project: project, size: 10)
                    Text(project.name)
                }
            }
            if project != nil, !done, subtasks != nil { Dot() }
            if !done, let subtasks { Text(TaskCopy.progress(subtasks)).monospacedDigit() }
        }
        .font(.caption).foregroundStyle(palette.ink3).lineLimit(1)
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
            // 入口不用系统占位灰：那样看起来像不能点
            Image(systemName: "plus").foregroundStyle(palette.ink2).frame(width: 44).accessibilityHidden(true)
            TextField(text: $text, prompt: Text("添加任务").foregroundStyle(palette.ink2)) { Text("添加任务") }
                .accessibilityLabel("添加任务")
                .frame(minHeight: 44)
                .contentShape(.rect)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
            if let projects, !projects.isEmpty {
                Menu {
                    Button(CaptureCopy.unfiled) { chosen = .some(nil) }
                    Divider()
                    ForEach(projects) { item in Button(item.name) { chosen = item.id } }
                } label: {
                    DestinationChip(project: current).frame(minHeight: 44).contentShape(.rect)
                }
                .accessibilityLabel("记到 \(CaptureCopy.destination(current))")
            }
        }
    }

    private var target: UUID? { chosen ?? project }
    private var current: Project? { projects?.first { $0.id == target } }

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
