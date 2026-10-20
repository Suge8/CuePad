#if os(macOS)
import SwiftUI

/// 项目页的任务：前几条没做完的任务连同它们的步骤，一行一件（可拖动、缩进，同任务面板）；没列出的与最近完成的在纸底写个数，点了在纸里原地展开、
/// 各自开合（规则见 `TaskFold`）。按 ui.md 的 Mac 开合规则一步到位：新行直接出现，同访达展开，不淡入、不挪动。
/// 收起其余任务时纸底那一行留在原来的屏幕位置（`TaskFoldAnchor`），长列表底部收起不会跳到卡片墙。
/// 段标题"任务 N"在纸外，与"资料""最近"同一个样子。行与任务面板同一种（`TaskLine`），标题后一格"下一步"（`TaskNext`）：交给的 Agent 要你做什么，或还没交出去的"开始"；要 Agent 做什么写在任务的正文里（任务浮窗）。
/// 会话的全部列表在侧栏，这里不另开一栏。
/// 纸与下面的资料、卡片墙同宽，行铺满纸：行尾的进度贴着纸的右边成一列，与任务面板的行同一个样子。
struct FocusBand: View {
    let data: ProjectPageData
    @Binding var position: ScrollPosition
    let anchor: TaskFoldAnchor
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var fold = DebugHooks.preset.taskFold

    private static let visibleTasks = 4
    /// 没做完的任务（含步骤）有这么多时，折起时列出的那几行之后的行按需建：全展开时普通栈要在点开的那一圈把每行都建出、量一遍（150 条约 130ms，Release）。
    /// 按总数定、不按开合定：换栈会让一直在的那几行也跟着重建。
    private static let lazyFrom = 20

    var body: some View {
        // 段标题在纸外，与下面的"资料""最近"同一个样子：一页三段，眼睛只学一次
        VStack(alignment: .leading, spacing: Spacing.sectionTitle) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("任务").font(Typography.sectionTitle).foregroundStyle(palette.ink)
                if data.taskCounts.open > 0 { Text("\(data.taskCounts.open)").font(Typography.sectionCount).foregroundStyle(palette.ink3) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            taskRows
            .padding(.horizontal, 20).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .paper(radius: 18)
        }
        .debugExposesTaskFold(active: active) { toggle(\.showsAll) }
    }

    @ViewBuilder private var taskRows: some View {
        let roots = data.tasks.roots
        let hidden = TaskFold.hidden(roots.count, limit: Self.visibleTasks)
        let shown = fold.shown(roots, limit: Self.visibleTasks)
        let done = data.taskCounts.done
        // 与任务面板同一种行；悬停的淡底是行的底，向两边让出去，字与栏标题对齐
        VStack(alignment: .leading, spacing: 0) {
            TaskOutline(
                tree: data.tasks, roots: shown,
                lazyAfter: data.tasks.ordered.count >= Self.lazyFrom ? TaskFold.foldedRows(data.tasks, limit: Self.visibleTasks) : nil
            ) { row in
                TaskLine(task: row.task, subtasks: data.subtasks[row.id], step: row.depth > 0)
            }
            if hidden > 0 || done > 0 {
                HStack(spacing: 6) {
                    if hidden > 0 { toggleButton(TaskCopy.more(hidden: hidden, expanded: fold.showsAll), open: fold.showsAll, \.showsAll) }
                    if hidden > 0, done > 0 { Dot() }
                    if done > 0 { toggleButton(TaskCopy.done(done), open: fold.showsDone, \.showsDone) }
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .padding(.horizontal, TaskMetrics.ringColumn + TaskMetrics.columnGap).padding(.vertical, 6)
                .taskFoldBar(anchor)
            }
            if fold.showsDone {
                // 同任务面板里已完成的行：淡一档，点圆圈回到待办
                ForEach(data.done) { TaskLine(task: $0) }
            }
            NewTaskField(project: data.project?.id).padding(.top, 2)
        }
    }

    /// 展开或收起：一步到位（不让大纲自己的挪位动画接手）；收起其余任务时把纸底这一行留在原处（`TaskFoldAnchor`）。
    private func toggle(_ key: WritableKeyPath<TaskFold, Bool>) {
        if key == \.showsAll, fold.showsAll { return anchor.collapse($fold, scrolling: $position) }
        withTransaction(\.disablesAnimations, true) { fold[keyPath: key].toggle() }
    }

    private func toggleButton(_ title: String, open: Bool, _ key: WritableKeyPath<TaskFold, Bool>) -> some View {
        Button { toggle(key) } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(open ? .collapse : .expand).font(.system(size: 8, weight: .semibold)).accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "已展开" : "已折叠")
    }
}

/// 下滚后收成的悬浮标题：一块玻璃写项目名与没做完的任务数；点一下回到顶部。
struct CompactFocus: View {
    let data: ProjectPageData
    let scrollToTop: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: scrollToTop) {
            HStack(spacing: 14) {
                HStack(spacing: 6) {
                    ProjectGlyph(project: data.project, size: 13)
                    Text(data.project?.name ?? "").font(Typography.toolbarTitle).lineLimit(1)
                }
                Label(data.taskCounts.open > 0 ? "任务 \(data.taskCounts.open)" : "任务", icon: .task).foregroundStyle(palette.ink2)
            }
            .font(Typography.toolbarLabel)
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 16).frame(height: Spacing.toolbarControl)
            .glass(in: .capsule, interactive: true)
        }
        .buttonStyle(PressStyle())
        // 放在工具栏里时系统默认只显示图标
        .labelStyle(.titleAndIcon)
        .help("回到顶部")
    }
}
#endif
