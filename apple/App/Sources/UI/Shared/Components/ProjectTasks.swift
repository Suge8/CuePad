import CueStore
import SwiftUI

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
                HStack(spacing: Spacing.item) {
                    NewTaskField(project: data.project?.id).newTaskDrop()
                    if data.doneCount > 0 { DoneFold(title: TaskCopy.done(data.doneCount), open: fold.showsDone) { toggle(\.showsDone) } }
                }
                .padding(.vertical, TaskMetrics.rowGap)
                if data.doneCount > 0 {
                    if fold.showsDone {
                        ForEach(data.done.prefix(doneShown)) { TaskLine(task: $0) }
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
            } action: { lane = $0.lowerBound - BubbleMetrics.leading - BubbleMetrics.stepLead...$0.upperBound }
        }
        .onChange(of: active ? lane : nil, initial: true) { workspace.press.lane = $1 }
        .onDisappear { workspace.press.lane = nil }
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

