#if os(macOS)
import SwiftUI

/// 展开收起按 docs/ui.md 的 Mac 开合规则一步到位。
/// 收起其余任务时纸底那一行留在原来的屏幕位置（`TaskFoldAnchor`），长列表底部收起不会跳到卡片墙。
/// 纸上不写"任务"的段标题：纸是页面最上面的第一块、行首都是任务圈，不用标题也认得出（读屏念"任务"）。
struct FocusBand: View {
    let data: ProjectPageData
    @Binding var position: ScrollPosition
    let anchor: TaskFoldAnchor
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active
    @State private var fold = DebugHooks.preset.taskFold

    private static let visibleTasks = 4
    /// 没做完的任务（含子任务）有这么多时，折起时列出的那几行之后的行按需建：全展开时普通栈要在点开的那一圈把每行都建出、量一遍（150 条约 130ms，Release）。
    /// 按总数定、不按开合定：换栈会让一直在的那几行也跟着重建。
    private static let lazyFrom = 20

    var body: some View {
        taskRows
        .padding(.horizontal, Spacing.panel).padding(.vertical, Spacing.inset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .paper()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务")
        .debugExposesTaskFold(active: active) { toggle(\.showsAll) }
    }

    @ViewBuilder private var taskRows: some View {
        let roots = data.tasks.roots
        let hidden = TaskFold.hidden(roots.count, limit: Self.visibleTasks)
        let shown = fold.shown(roots, limit: Self.visibleTasks)
        let done = data.taskCounts.done
        // 悬停的淡底是行的底，向两边让出去，字与栏标题对齐
        VStack(alignment: .leading, spacing: 0) {
            TaskOutline(
                tree: data.tasks, roots: shown,
                lazyAfter: data.tasks.ordered.count >= Self.lazyFrom ? TaskFold.foldedRows(data.tasks, limit: Self.visibleTasks) : nil
            ) { row in
                TaskLine(task: row.task, subtasks: data.subtasks[row.id], step: row.depth > 0)
            }
            if fold.showsDone {
                ForEach(data.done) { TaskLine(task: $0) }
            }
            HStack(spacing: Spacing.item) {
                NewTaskField(project: data.project?.id)
                if hidden > 0 { toggleButton(TaskCopy.more(hidden: hidden, expanded: fold.showsAll), open: fold.showsAll, \.showsAll) }
                if hidden > 0, done > 0 { Dot() }
                if done > 0 { toggleButton(TaskCopy.done(done), open: fold.showsDone, \.showsDone) }
            }
            .font(Typography.meta).foregroundStyle(palette.ink3)
            .padding(.top, Spacing.hair)
            .taskFoldBar(anchor)
            .newTaskDrop()
        }
    }

    private func toggle(_ key: WritableKeyPath<TaskFold, Bool>) {
        if key == \.showsAll, fold.showsAll { return anchor.collapse($fold, scrolling: $position) }
        withTransaction(\.disablesAnimations, true) { fold[keyPath: key].toggle() }
    }

    private func toggleButton(_ title: String, open: Bool, _ key: WritableKeyPath<TaskFold, Bool>) -> some View {
        Button { toggle(key) } label: {
            HStack(spacing: Spacing.hair) {
                Text(title)
                Image(open ? .collapse : .expand).font(Glyph.mark).accessibilityHidden(true)
            }
            .fixedSize()
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.inline))
        .accessibilityValue(open ? "已展开" : "已折叠")
    }
}

/// 任务图标接数，不写"任务"二字：图标已经说了。
struct CompactFocus: View {
    let data: ProjectPageData
    let scrollToTop: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: scrollToTop) {
            HStack(spacing: Spacing.item) {
                Image(.above).accessibilityHidden(true)
                if data.taskCounts.open > 0 {
                    Label { Text(data.taskCounts.open, format: .number).monospacedDigit() } icon: { Image(.task) }
                        .foregroundStyle(palette.ink2)
                }
            }
        }
        .buttonStyle(ControlButtonStyle(kind: .glass))
        .help("回到顶部")
        .accessibilityLabel("回到顶部")
        .accessibilityValue(data.taskCounts.open > 0 ? Text("\(data.taskCounts.open) 个任务没做完") : Text(verbatim: ""))
    }
}
#endif
