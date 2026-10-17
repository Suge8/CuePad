#if os(iOS)
import CueStore
import SwiftUI

/// 任务页（书架上的"任务"一行、iPad 侧栏进入）：列表顶上一行快速添加（↩ 即一条，落当前项目或未分类，可换），
/// 跟着列表一起滚走——它是一张纸、不是玻璃，钉在顶栏下会把滚过去的列表切成上下两截；回到顶就能看到。下面三组（`TaskBoard`）：
/// 进行中一张纸，跨项目、最近开始的在前，行的标题后跟项目小图标；待办按项目分段，每段一张纸、段头写项目；最近完成（折起）。
/// 步骤缩进跟在上级下（`TaskOutline`：长按拖动排序、拖到一条上成为它的步骤、拖进待办别的段换项目，拖动不改状态；进行中按开始时间排，两行之间不能落；轻扫见 `CardMenu.swipes`），
/// 行是全 App 共用的 `TaskLine`。没有没做完的任务时是吉祥物加一句现状。
/// 宽屏（iPad）里列表不铺满：标题与行尾的旁注隔太远读不成一行。
struct TasksScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var board: TaskBoard?
    @State private var showsCompleted = false
    @Environment(Navigation.self) private var navigation

    private static let readableWidth: CGFloat = 720
    private static let radius: CGFloat = 16

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if let board { content(board) }
            }
            .onChange(of: board?.done.last?.id) {
                if DebugHooks.preset.showsDone, let last = board?.done.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        // 没有没做完的任务时页头不写计数：下面的空态已经说了
        .floatingHeader("任务", detail: board.flatMap { $0.counts.open == 0 ? nil : $0.counts.summary } ?? "")
        .onAppear { if DebugHooks.preset.showsDone { showsCompleted = true } }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: board?.order)
        .observing(services.store, into: $board, onError: workspace.fail) {
            try TaskBoard.read(from: $0)
        }
    }

    private func content(_ board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            NewTaskLine(project: navigation.currentProject, projects: workspace.catalog?.projects)
                .padding(.horizontal, 6)
                .background(palette.paper, in: .rect(cornerRadius: Self.radius, style: .continuous))
            if board.inProgress.isEmpty && board.todo.isEmpty {
                EmptyState(
                    mascot: board.done.isEmpty ? .empty : .clean, title: board.done.isEmpty ? "还没有任务" : "全部完成了",
                    message: board.done.isEmpty ? "在上面写一条" : nil, waitsForSync: true)
                .transition(Motion.item)
            }
            if !board.inProgress.isEmpty { inProgress(board) }
            if !board.todo.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    TaskGroupHeader(title: "待办", count: board.counts.todo).padding(.horizontal, 4)
                    ForEach(board.todo) { section($0, in: board) }
                }
            }
            if !board.done.isEmpty { completed(board.done, count: board.counts.done) }
        }
        .padding(.horizontal, 16).padding(.bottom, 24)
        .frame(maxWidth: Self.readableWidth)
        .frame(maxWidth: .infinity)
    }

    /// 进行中：跨项目，行的标题后跟项目小图标（步骤不跟，它跟着上级）。
    private func inProgress(_ board: TaskBoard) -> some View {
        let projects = Dictionary(uniqueKeysWithValues: board.inProgress.map { ($0.id, $0.project) })
        return VStack(alignment: .leading, spacing: 8) {
            TaskGroupHeader(title: "进行中", count: board.counts.inProgress).padding(.horizontal, 4)
            paper {
                TaskOutline(tree: board.tree, roots: board.inProgress.map(\.id), gaps: false) { row in
                    TaskLine(task: row.task, subtasks: board.subtasks[row.id], step: row.depth > 0, project: projects[row.id] ?? nil)
                }
            }
        }
        .transition(Motion.item)
    }

    private func section(_ section: TaskBoard.Section, in board: TaskBoard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TaskSectionHeader(project: section.project, count: section.roots.count).padding(.horizontal, 4)
            paper {
                TaskOutline(tree: board.tree, roots: section.roots) { row in
                    TaskLine(task: row.task, subtasks: board.subtasks[row.id], step: row.depth > 0)
                }
            }
        }
        .transition(Motion.item)
    }

    private func paper(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
            .background(palette.paper, in: .rect(cornerRadius: Self.radius, style: .continuous))
    }

    private func completed(_ rows: [TaskBoard.Row], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { showsCompleted.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("最近完成 \(count)")
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
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
                paper {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { TaskLine(task: $0.task, project: $0.project).id($0.id) }
                    }
                }
                .transition(.opacity)
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
