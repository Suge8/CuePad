import CueStore
import SwiftUI

/// 项目页的任务区（三端同一份）：不装在纸里，行直接落在桌面上。从上到下是没做完的任务、"还有 N 条"、"添加任务"（行尾是"已完成 N"），各占一行，与任务行同高、同一种底；整块不宽过阅读栏（`Spacing.reading`）。
/// 不写"任务"的段标题、也不写"还剩几件"：下面那几行自己就是，看这个项目的进展在栏头点项目名出的那几项里（`ProjectActions`）。
/// 行首都是任务圈，不用标题也认得出（读屏念"任务"）。
/// 收起其余任务一步到位，"收起"那一行留在原来的屏幕位置（`TaskFoldAnchor`：没有能跟着弹簧走的位移），换上来的那几行淡入。
/// Mac 展开也一步到位、不逐帧排版；手机展开跟着弹簧长开。
struct ProjectTasks: View {
    let data: ProjectPageData
    @Binding var position: ScrollPosition
    let anchor: TaskFoldAnchor
    @State private var fold = DebugHooks.preset.taskFold
    @State private var collapses = 0
    @State private var lane: ClosedRange<CGFloat>?
    @State private var doneShown = donePage
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
    private static let donePage = 5

    var body: some View {
        let roots = data.tasks.roots
        let kept = TaskFold.folded(data.tasks, limit: Self.visibleTasks)
        let hidden = roots.count - kept.count
        let counts = data.taskCounts
        VStack(alignment: .leading, spacing: 0) {
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
                    FoldRow(title: TaskCopy.more(hidden: hidden, expanded: fold.showsAll), open: fold.showsAll) { toggle(\.showsAll) }
                        .taskFoldBar(anchor)
                }
                // 添加与"已完成"同在一行：两行都常年在、各只有几个字，叠着占两行的高
                HStack(spacing: Spacing.item) {
                    NewTaskField(project: data.project?.id).newTaskDrop()
                    if counts.done > 0 { DoneFold(title: TaskCopy.done(counts.done), open: fold.showsDone) { toggle(\.showsDone) } }
                }
                .padding(.vertical, TaskMetrics.rowGap)
                if counts.done > 0 {
                    if fold.showsDone {
                        ForEach(data.done.prefix(doneShown)) { TaskLine(task: $0) }
                        // 做完的会越攒越多：一次只列一小段，要看更早的再往下要，不一点开就把页拉长几屏
                        if data.done.count > doneShown {
                            FoldRow(title: TaskCopy.more(hidden: data.done.count - doneShown, expanded: false), open: nil) {
                                doneShown += Self.donePage
                            }
                        }
                    }
                }
            }
            .padding(.leading, -TaskMetrics.ringInset)
            .onGeometryChange(for: ClosedRange<CGFloat>.self) {
                let frame = $0.frame(in: .global)
                return frame.minX...frame.maxX
            } action: { lane = $0.lowerBound - BubbleMetrics.padding.leading - BubbleMetrics.stepLead...$0.upperBound }
        }
        .onChange(of: active ? lane : nil, initial: true) { workspace.press.lane = $1 }
        .onDisappear { workspace.press.lane = nil }
        // 宽窗口里不横着铺满：标题与行尾的时间、"开始"要在一眼之内
        .frame(maxWidth: Spacing.reading, alignment: .topLeading)
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
        if key == \.showsDone { doneShown = Self.donePage }
        #if os(macOS)
        withTransaction(\.disablesAnimations, true) { fold[keyPath: key].toggle() }
        #else
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { fold[keyPath: key].toggle() }
        #endif
    }
}

/// "添加任务"那一行行尾的"已完成 N"：字在前、开合的记号在后，开着转朝下。
private struct DoneFold: View {
    let title: String
    let open: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.tight) {
                Text(title).font(Typography.body).fixedSize()
                Chevron(.forward).rotationEffect(.degrees(open ? 90 : 0))
            }
            .foregroundStyle(palette.ink3)
            .padding(.horizontal, Spacing.item)
            .frame(minHeight: TaskMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.inline))
        .accessibilityValue(open ? "已展开" : "已折叠")
    }
}

/// 开合其余任务的那一行：记号在任务圈那一列，字与任务标题对齐。开合的记号同会话条的项目行：朝右的箭头，开着转朝下。
/// `open` 为 nil 是"再列几条"：不是开合，箭头一直朝下。
private struct FoldRow: View {
    let title: String
    let open: Bool?
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: TaskMetrics.columnGap) {
                Chevron(open == nil ? .expand : .forward).rotationEffect(.degrees(open == true ? 90 : 0)).frame(width: TaskMetrics.ringColumn)
                Text(title).font(Typography.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(palette.ink3)
            .frame(minHeight: TaskMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .padding(.vertical, TaskMetrics.rowGap)
        .accessibilityValue(open.map { $0 ? "已展开" : "已折叠" } ?? "")
    }
}

