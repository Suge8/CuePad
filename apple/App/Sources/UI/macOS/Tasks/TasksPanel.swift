#if os(macOS)
import CueStore
import SwiftUI

/// 右上角面板：顶上一行快速添加；下面是共用的任务看板（`TaskBoard`）——进行中（跨项目、最近开始的在前，标题后跟项目小图标，悬停写全名）、
/// 待办（按项目分段，段头写项目）、最近完成（折起），步骤缩进跟在任务下（`TaskOutline`：按住拖动排序、拖到一条上成为它的步骤、
/// 横向拖改层级、拖进待办别的段换项目，拖动不改状态；进行中按开始时间排，两行之间不能落），
/// 行与项目页同一种（`TaskLine`）。点任务弹出任务浮窗（面板留着）。
struct TasksPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @State private var board: TaskBoard?
    @State private var showsCompleted = false

    /// 看得见的行（含步骤，"最近完成"展开时再加上它）多到面板放不下时（行至少 34pt，640pt 的面板里二十行就满了）行按需建、面板定高：
    /// 普通栈要在打开的那一圈把上百行都量一遍（大库上约 150ms）。不多时照旧由内容撑开高度，懒加载栈在高度跟着内容变时会漏画。
    private static let lazyFrom = 20

    private func isLazy(_ board: TaskBoard?) -> Bool {
        guard let board else { return false }
        let open = board.tree.ordered.count
        return open + (showsCompleted ? board.done.count : 0) >= Self.lazyFrom
    }

    var body: some View {
        let lazy = isLazy(board)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("任务").font(Typography.sectionTitle)
                if let board, board.counts.open > 0 { Text("\(board.counts.open)").font(Typography.sectionCount).foregroundStyle(palette.ink2) }
                Spacer()
                Button("关闭", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(palette.ink2)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 6)
            NewTaskField(project: workspace.currentProject, choosesProject: true, autofocus: true)
                .padding(.horizontal, 20).padding(.bottom, 6)
            ScrollView {
                if let board { list(board, lazy: lazy) }
            }
        }
        .frame(width: 400)
        .frame(height: lazy ? 640 : nil)
        .frame(maxHeight: 640)
        .fixedSize(horizontal: false, vertical: !lazy)
        // 浮在项目页上、背后是卡片与任务纸，自己是一整页字（`GlassInk.solid`）
        .rowContainer(.rect(cornerRadius: 26))
        .glass(in: .rect(cornerRadius: 26), ink: .solid)
        // 面板挂在页面之外：读"交给了哪个会话"的行在这里补上
        .modifier(WindowCardAgents(workspace: workspace))
        .observing(services.store, into: $board, onError: workspace.fail) {
            try TaskBoard.read(from: $0)
        }
    }

    // 任务不多时不用 LazyVStack：面板高度随内容撑开，懒加载栈在行于两组之间移动、展开"最近完成"时会漏画或留下旧状态的行。
    @ViewBuilder private func list(_ board: TaskBoard, lazy: Bool) -> some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: 0) { listContent(board, lazy: true) }
                .padding(.bottom, 12)
                .animation(Motion.quick, value: board.order)
        } else {
            VStack(alignment: .leading, spacing: 0) { listContent(board, lazy: false) }
                .padding(.bottom, 12)
                .animation(Motion.quick, value: board.order)
        }
    }

    @ViewBuilder private func listContent(_ board: TaskBoard, lazy: Bool) -> some View {
        if board.inProgress.isEmpty && board.todo.isEmpty {
            EmptyState(
                mascot: board.done.isEmpty ? .empty : .clean, title: board.done.isEmpty ? "还没有任务" : "全部完成了",
                message: board.done.isEmpty ? "在上面写一条" : nil, compact: true
            ) { EmptyView() }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        if !board.inProgress.isEmpty {
            let projects = Dictionary(uniqueKeysWithValues: board.inProgress.map { ($0.id, $0.project) })
            group("进行中", count: board.counts.inProgress)
            TaskOutline(tree: board.tree, roots: board.inProgress.map(\.id), gaps: false, lazyAfter: lazy ? 0 : nil) { row in
                TaskLine(task: row.task, subtasks: board.subtasks[row.id], step: row.depth > 0, project: projects[row.id] ?? nil)
            }
            .padding(.horizontal, 20)
        }
        if !board.todo.isEmpty {
            group("待办", count: board.counts.todo)
            ForEach(board.todo) { section($0, in: board, lazy: lazy) }
        }
        if !board.done.isEmpty {
            HStack {
                Button {
                    withAnimation(Motion.quick) { showsCompleted.toggle() }
                } label: {
                    Label("最近完成 \(board.counts.done)", systemImage: showsCompleted ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsCompleted ? "已展开" : "已折叠")
                Spacer()
                Button("全部归档") { workspace.attempt { try await workspace.archiveCompletedTasks() } }
                    .buttonStyle(.plain).help("把最近完成的任务全部归档：不占列表，照样搜得到")
            }
            .font(Typography.label).foregroundStyle(palette.ink2)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
            if showsCompleted { rows(board.done) }
        }
    }

    private func group(_ title: String, count: Int) -> some View {
        TaskGroupHeader(title: title, count: count)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 2)
    }

    @ViewBuilder private func section(_ section: TaskBoard.Section, in board: TaskBoard, lazy: Bool) -> some View {
        TaskSectionHeader(project: section.project, count: section.roots.count)
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 2)
        TaskOutline(tree: board.tree, roots: section.roots, lazyAfter: lazy ? 0 : nil) { row in
            TaskLine(task: row.task, subtasks: board.subtasks[row.id], step: row.depth > 0)
        }
        .padding(.horizontal, 20)
    }

    private func rows(_ items: [TaskBoard.Row]) -> some View {
        ForEach(items) { row in
            TaskLine(task: row.task, project: row.project)
                .padding(.horizontal, 20)
        }
    }
}
#endif
