#if os(iOS)
import CueStore
import SwiftUI

/// 任务页（iPhone 底部一排的"任务"、宽屏侧栏的"任务"）：两组（`TaskBoard`）直接排在桌面上，不垫纸——
/// 进行中在上：跨项目、最近开始的在前，标题后跟项目小图标；没有步骤的那几条"下一步"写成第二行（会话状态或"▶ 开始"，`TaskLine.spelled`），
/// 有步骤的旁注是步骤数、步骤跟在下面；组标题右边"N 个会话在跑 ›"去会话页（`RunningSessions`）。
/// 待办收着时露出最近添加的几条（`TaskBoard.latestTodo`，标题后跟项目小图标），末行"还有 N 项"原地展开成按项目分的段（段头写项目），末行换成"收起"；
/// 最近完成折着。步骤缩进跟在上级下（`TaskOutline`：长按拖动排序、拖到一条上成为它的步骤、拖进待办别的段换项目，拖动不改状态；
/// 进行中按开始时间排、露出的那几条按添加时间排，两行之间不能落；轻扫见 `CardMenu.swipes`），行是全 App 共用的 `TaskLine`。
/// 添加任务在右上角"+"：点了列表顶上浮出一行输入（`NewTaskLine`，↩ 即一条，落当前项目或未分类，可换），失焦且没写字时收回。
/// 没有没做完的任务时是吉祥物加一句现状。宽屏（iPad）里列表不铺满：标题与行尾的旁注隔太远读不成一行。
struct TasksScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var board: TaskBoard?
    @State private var showsCompleted = false
    @State private var showsAllTodo = false
    @State private var adding = false
    @Environment(Navigation.self) private var navigation

    private static let readableWidth: CGFloat = 720
    private static let radius: CGFloat = 16
    private static let newTask = "newTask"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let board { content(board) }
            }
            // 滚动收起键盘：浮出的添加那一行没写字时跟着收回（`NewTaskLine.dismiss`）
            .scrollDismissesKeyboard(.immediately)
            .onChange(of: board?.done.last?.id) {
                if DebugHooks.preset.showsDone, let last = board?.done.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
            // 浮出的那一行在列表最上面：滚走了就滚回来
            .onChange(of: adding) {
                if adding { withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { proxy.scrollTo(Self.newTask, anchor: .top) } }
            }
            // 没有没做完的任务时页头不写计数：下面的空态已经说了
            .floatingHeader("任务", detail: board.flatMap { $0.counts.open == 0 ? nil : $0.counts.summary } ?? "") {
                Button("添加任务", icon: .add) { adding = true }
            }
        }
        .onAppear { if DebugHooks.preset.showsDone { showsCompleted = true } }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: board?.order)
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: adding)
        .observing(services.store, into: $board, onError: workspace.fail) {
            try TaskBoard.read(from: $0)
        }
    }

    /// 行按需建（懒加载栈，组里的行也是，`TaskOutline.lazyAfter`）：普通栈在进页那一圈把所有行都建出来量一遍，150 条待办进页约 380ms。
    private func content(_ board: TaskBoard) -> some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if adding {
                NewTaskLine(project: navigation.currentProject, projects: workspace.catalog?.projects) { adding = false }
                    .padding(.horizontal, 6)
                    .background(palette.paper, in: .rect(cornerRadius: Self.radius, style: .continuous))
                    .id(Self.newTask)
                    .transition(Motion.item)
            }
            if board.inProgress.isEmpty && board.todo.isEmpty {
                EmptyState(
                    mascot: board.done.isEmpty ? .empty : .clean, title: board.done.isEmpty ? "还没有任务" : "全部完成了",
                    message: board.done.isEmpty ? "点右上角的 + 写一条" : nil, waitsForSync: true)
                .transition(Motion.item)
            }
            if !board.inProgress.isEmpty { inProgress(board) }
            if !board.todo.isEmpty { todo(board) }
            if !board.done.isEmpty { completed(board.done, count: board.counts.done) }
        }
        .padding(.horizontal, 16).padding(.bottom, 24)
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    /// 进行中：跨项目，行的标题后跟项目小图标（步骤不跟，它跟着上级）。
    private func inProgress(_ board: TaskBoard) -> some View {
        let projects = Dictionary(uniqueKeysWithValues: board.inProgress.map { ($0.id, $0.project) })
        return VStack(alignment: .leading, spacing: 4) {
            // 放不下一行（辅助字号）时"N 个会话在跑"换到标题下面
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    TaskGroupHeader(title: "进行中", count: board.counts.inProgress)
                    Spacer(minLength: 8)
                    RunningSessions().fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    TaskGroupHeader(title: "进行中", count: board.counts.inProgress)
                    RunningSessions()
                }
            }
            .padding(.horizontal, 4)
            TaskOutline(tree: board.tree, roots: board.inProgress.map(\.id), gaps: false, lazyAfter: 0) { row in
                TaskLine(
                    task: row.task, subtasks: board.subtasks[row.id], step: row.depth > 0, project: projects[row.id] ?? nil,
                    spelled: row.depth == 0)
            }
            .padding(.leading, Self.lineInset)
        }
        .transition(Motion.item)
    }

    /// 待办：收着时露出最近添加的几条，其余收成末行"还有 N 项"；展开后按项目分段，末行"收起"。
    private func todo(_ board: TaskBoard) -> some View {
        let total = board.todo.reduce(0) { $0 + $1.roots.count }
        let hidden = total - board.latestTodo.count
        let expanded = showsAllTodo && hidden > 0
        let projects = Dictionary(uniqueKeysWithValues: board.latestTodo.map { ($0.id, $0.project) })
        return LazyVStack(alignment: .leading, spacing: expanded ? 12 : 4) {
            TaskGroupHeader(title: "待办", count: board.counts.todo).padding(.horizontal, 4)
            if expanded {
                ForEach(board.todo) { section($0, in: board) }
            } else {
                TaskOutline(tree: board.tree, roots: board.latestTodo.map(\.id), gaps: false, lazyAfter: 0) { row in
                    TaskLine(task: row.task, subtasks: board.subtasks[row.id], step: row.depth > 0, project: projects[row.id] ?? nil)
                }
                .padding(.leading, Self.lineInset)
            }
            if hidden > 0 { todoFold(hidden: hidden, expanded: expanded) }
        }
        .transition(Motion.item)
    }

    private func section(_ section: TaskBoard.Section, in board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TaskSectionHeader(project: section.project, count: section.roots.count).padding(.horizontal, 4)
            TaskOutline(tree: board.tree, roots: section.roots, lazyAfter: 0) { row in
                TaskLine(task: row.task, subtasks: board.subtasks[row.id], step: row.depth > 0)
            }
            .padding(.leading, Self.lineInset)
        }
        .transition(Motion.item)
    }

    /// 待办的末行：收着时"还有 N 项"，展开后"收起"；字与行的标题对齐。
    private func todoFold(hidden: Int, expanded: Bool) -> some View {
        Button {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { showsAllTodo.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(expanded ? "收起" : "还有 \(hidden) 项").monospacedDigit()
                Image(.forward).font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? -90 : 0)).accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(.subheadline).foregroundStyle(palette.ink3)
            .padding(.leading, Self.lineInset + TaskMetrics.ringColumn + TaskMetrics.columnGap)
            .frame(minHeight: 44).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "收起待办" : "还有 \(hidden) 项待办")
        .accessibilityExpanded(expanded)
    }

    /// 行比组标题往左多出的那一截：圈在 44pt 的点按格里居中，圈的左缘对着组标题的字。
    private static let lineInset: CGFloat = -8

    private func completed(_ rows: [TaskBoard.Row], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button {
                    withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { showsCompleted.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("最近完成 \(count)")
                        Image(.forward).font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(showsCompleted ? 90 : 0)).accessibilityHidden(true)
                        Spacer()
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 4)
                    .frame(minHeight: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsCompleted ? "已展开" : "已折叠")
                // 做完的一键收走：归档后不占列表，照样搜得到
                Button("全部归档") { workspace.attempt { try await workspace.archiveCompletedTasks() } }
                    .font(.subheadline).foregroundStyle(palette.ink3)
                    .padding(.horizontal, 4).frame(minHeight: 44).contentShape(.rect)
                    .buttonStyle(.plain)
            }
            if showsCompleted {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { TaskLine(task: $0.task, project: $0.project).id($0.id) }
                }
                .padding(.leading, Self.lineInset)
                .transition(.opacity)
            }
        }
    }
}

/// 进行中组标题右边的"N 个会话在跑 ›"（`Workspace.liveWork` 的在跑数，同 Cue 页头面板的区头），点了去会话页；没有在跑的不写。
/// 单独一个视图读会话：会话状态变化时只重算它，不重算整页任务。
private struct RunningSessions: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        let working = workspace.liveWork.working
        if working > 0 {
            Button { navigation.show(.agent) } label: {
                HStack(spacing: 3) {
                    Text("\(working) 个会话在跑").contentTransition(.numericText()).animation(Motion.snappy, value: working)
                    Image(.forward).font(.footnote.weight(.semibold)).accessibilityHidden(true)
                }
                .font(.subheadline.monospacedDigit()).foregroundStyle(palette.ink3)
                .frame(minHeight: 44).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .accessibilityHint("看全部会话")
        }
    }
}

/// 一行新建任务：↩ 添加并保持焦点，便于连续输入。给了 `projects` 时尾部可选挂到哪个项目。
/// 给了 `dismiss`（任务页右上角"+"浮出的那一行）：出现即聚焦，失焦时没写字就收回。
struct NewTaskLine: View {
    let project: UUID?
    var projects: [Project]?
    var dismiss: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var chosen: UUID??
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            // 入口不用系统占位灰：那样看起来像不能点
            Image(.add).foregroundStyle(palette.ink2).frame(width: 44).accessibilityHidden(true)
            TextField("添加任务", text: $text, palette: palette)
                .accessibilityLabel("添加任务")
                .frame(minHeight: 44)
                .contentShape(.rect)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit(add)
                .onAppear { if dismiss != nil { focused = true } }
                .onChange(of: focused) { if !focused, text.trimmingCharacters(in: .whitespaces).isEmpty { dismiss?() } }
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
