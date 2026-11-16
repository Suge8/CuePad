import CueStore
import SwiftUI

/// 项目页的任务区（三端同一份）：不装在纸里，行直接落在桌面上。最上面一条进度（点它去只看这个项目的进展），
/// 下面依次是没做完的任务、"还有 N 条"、"添加任务"、"已完成 N"，各占一行，与任务行同高、同一种底。
/// 不写"任务"的段标题：行首都是任务圈，不用标题也认得出（读屏念"任务"）。
/// 收起其余任务一步到位，"收起"那一行留在原来的屏幕位置（`TaskFoldAnchor`：没有能跟着弹簧走的位移），换上来的那几行淡入。
/// Mac 展开也一步到位、不逐帧排版；手机展开跟着弹簧长开。
struct ProjectTasks: View {
    let data: ProjectPageData
    @Binding var position: ScrollPosition
    let anchor: TaskFoldAnchor
    @State private var fold = DebugHooks.preset.taskFold
    @State private var collapses = 0
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    @Environment(\.pageActive) private var active
    private static let visibleTasks = 5
    #else
    private let active = true
    private static let visibleTasks = 4
    #endif

    /// 没做完的任务（含子任务）有这么多时，折起时列出的那几行之后的行按需建：全展开时普通栈要在点开的那一圈把每行都建出、量一遍（150 条约 130ms，Release）。
    /// 按总数定、不按开合定：换栈会让一直在的那几行也跟着重建、淡出再淡入。
    private static let lazyFrom = 20
    private static let revealDuration = 0.16

    var body: some View {
        let roots = data.tasks.roots
        let kept = TaskFold.folded(data.tasks, limit: Self.visibleTasks)
        let hidden = roots.count - kept.count
        let counts = data.taskCounts
        VStack(alignment: .leading, spacing: 0) {
            if counts.total > 0, let project = data.project?.id {
                TaskMeter(counts: counts) { workspace.showProgress(of: project) }.padding(.bottom, Spacing.tight)
            }
            VStack(alignment: .leading, spacing: 0) {
                if !roots.isEmpty {
                    TaskOutline(
                        tree: data.tasks, roots: fold.showsAll ? nil : kept,
                        lazyAfter: data.tasks.ordered.count >= Self.lazyFrom ? data.tasks.rows(of: kept).count : nil
                    ) { row in
                        TaskLine(task: row.task, subtasks: data.subtasks[row.id], step: row.depth > 0)
                    }
                    .keyframeAnimator(initialValue: 1.0, trigger: collapses) { $0.opacity($1) } keyframes: { _ in
                        MoveKeyframe(0.0)
                        LinearKeyframe(1.0, duration: Self.revealDuration)
                    }
                }
                if hidden > 0 {
                    FoldRow(title: TaskCopy.more(hidden: hidden, expanded: fold.showsAll), open: fold.showsAll, closed: .expand, turn: 180) { toggle(\.showsAll) }
                        .taskFoldBar(anchor)
                }
                NewTaskField(project: data.project?.id).padding(.vertical, TaskMetrics.rowGap).newTaskDrop()
                if counts.done > 0 {
                    FoldRow(title: TaskCopy.done(counts.done), open: fold.showsDone, closed: .forward, turn: 90) { toggle(\.showsDone) }
                    if fold.showsDone { ForEach(data.done) { TaskLine(task: $0) } }
                }
            }
            .padding(.leading, -TaskMetrics.ringInset)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("任务")
        .debugExposesTaskFold(active: active) { toggle(\.showsAll) }
    }

    private func toggle(_ key: WritableKeyPath<TaskFold, Bool>) {
        if key == \.showsAll, fold.showsAll {
            collapses += 1
            return anchor.collapse($fold, scrolling: $position)
        }
        #if os(macOS)
        withTransaction(\.disablesAnimations, true) { fold[keyPath: key].toggle() }
        #else
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { fold[keyPath: key].toggle() }
        #endif
    }
}

private extension TaskCounts {
    var total: Int { inProgress + todo + done }
}

/// 开合其余任务、已完成的那一行：记号在任务圈那一列，字与任务标题对齐。
private struct FoldRow: View {
    let title: String
    let open: Bool
    let closed: Chevron.Direction
    let turn: Double
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: TaskMetrics.columnGap) {
                Chevron(closed).rotationEffect(.degrees(open ? turn : 0)).frame(width: TaskMetrics.ringColumn)
                Text(title).font(Typography.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(palette.ink3)
            .frame(minHeight: TaskMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .padding(.vertical, TaskMetrics.rowGap)
        .accessibilityValue(open ? "已展开" : "已折叠")
    }
}

/// 这个项目的任务做到哪：做完的一截是墨、在做的一截是靛青（正在发生的事）、其余是轨道；数写做完的与总数。
/// 点它去进展页只看这个项目：项目页不另摆"看进展"的钮。
private struct TaskMeter: View {
    let counts: TaskCounts
    let action: () -> Void
    @Environment(\.palette) private var palette

    private static let height: CGFloat = 6
    /// 条不随页宽拉长：宽屏上一整行的墨条比下面的任务都重。
    private static let width: CGFloat = 240

    var body: some View {
        let total = CGFloat(counts.total), done = CGFloat(counts.done), moving = CGFloat(counts.done + counts.inProgress)
        Button(action: action) {
            HStack(spacing: Spacing.group) {
                Capsule().fill(palette.track).frame(maxWidth: Self.width).frame(height: Self.height)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            ZStack(alignment: .leading) {
                                if moving > done { Capsule().fill(palette.signature).frame(width: max(width * moving / total, Self.height)) }
                                if done > 0 { Capsule().fill(palette.ink).frame(width: max(width * done / total, Self.height)) }
                            }
                        }
                    }
                    .animation(Motion.nudge, value: counts)
                Text(verbatim: "\(counts.done)/\(counts.total)").font(TaskMetrics.caption).monospacedDigit()
                Chevron(.forward)
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.ink3)
            .frame(minHeight: TaskMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .help("看这个项目的进展")
        .accessibilityLabel("看这个项目的进展")
        .accessibilityValue("已完成 \(counts.done)，共 \(counts.total)")
    }
}
