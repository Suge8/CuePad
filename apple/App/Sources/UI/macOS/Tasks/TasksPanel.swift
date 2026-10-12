#if os(macOS)
import CueStore
import SwiftUI

/// 右上角面板：顶上一行快速添加；下面是共用的任务看板（`TaskBoard`）——进行中、待办、最近完成（折起），跨项目，
/// 子任务缩进跟在上级下、提示词列在各自的任务下（`TaskOutline` 与 `TaskRow`：按住拖动排序、拖到一条上成为它的子任务、横向拖改层级），
/// 顶层写所在项目，交给 Pi 的写那个会话此刻的状态。点任务弹出任务浮层（面板留着），点提示词进编辑页。
struct TasksPanel: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @State private var board: TaskBoard?
    @State private var showsCompleted = false

    /// 看得见的行（含默认展开的子任务，"最近完成"展开时再加上它）多到面板放不下时（行至少 34pt，640pt 的面板里二十行就满了）行按需建、面板定高：
    /// 普通栈要在打开的那一圈把上百行都量一遍（大库上约 150ms）。不多时照旧由内容撑开高度，懒加载栈在高度跟着内容变时会漏画。
    private static let lazyFrom = 20

    private func isLazy(_ board: TaskBoard?) -> Bool {
        guard let board else { return false }
        let open = board.tree.rows(of: (board.inProgress + board.todo).map(\.id), toggled: [])
        let prompts = open.reduce(0) { $0 + (board.prompts[$1.id]?.count ?? 0) }
        return open.count + prompts + (showsCompleted ? board.done.count : 0) >= Self.lazyFrom
    }

    var body: some View {
        let lazy = isLazy(board)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("任务").font(Typography.sectionTitle)
                if let board { Text("\(board.counts.inProgress + board.counts.todo)").font(Typography.sectionCount).foregroundStyle(.secondary) }
                Spacer()
                Button("关闭", systemImage: "xmark") { close() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
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
        .glass(in: .rect(cornerRadius: 26), ink: .solid)
        // 面板挂在页面之外：提示词行读的"交给了哪个会话"在这里补上
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
            Text(board.done.isEmpty ? "还没有任务，在上面写一条" : "全部完成了").font(Typography.secondary).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        section("进行中", board.inProgress, count: board.counts.inProgress, in: board, lazy: lazy)
        section("待办", board.todo, count: board.counts.todo, in: board, lazy: lazy)
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
            .font(Typography.label).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
            if showsCompleted { rows(board.done) }
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [TaskBoard.Row], count: Int, in board: TaskBoard, lazy: Bool) -> some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").foregroundStyle(.tertiary)
            }
            .font(Typography.label).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
            TaskOutline(tree: board.tree, roots: items.map(\.id), lazy: lazy, folds: { TaskRow.folds($0, prompts: board.prompts) }) { row in
                let info = board.rows[row.id]
                TaskRow(
                    task: row.task, depth: row.depth, project: row.depth == 0 ? info?.project : nil,
                    session: info?.session, delivery: info?.delivery, marks: board.children[row.id],
                    prompts: board.prompts[row.id] ?? [], expanded: row.isExpanded)
            }
            .padding(.horizontal, 12)
        }
    }

    private func rows(_ items: [TaskBoard.Row]) -> some View {
        ForEach(items) { row in
            TaskRow(task: row.task, project: row.project, session: row.session, delivery: row.delivery)
                .padding(.horizontal, 12)
        }
    }
}
#endif
