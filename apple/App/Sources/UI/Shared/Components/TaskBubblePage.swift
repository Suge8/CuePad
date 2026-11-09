import CueEditor
import CueStore
import SwiftUI

/// 标题是正文的首段，同一个编辑器（`CardEditing` 的 `titled`），从第一帧就在、就可编辑：点下去字不挪、行高不变、纸不变高（没有"先显示字、点了换输入框"的那一下）。
/// 气泡里不建子任务：拆子任务是 Agent 与 Cue 的事，手动的在任务大纲里把任务拖到它下面（`TaskTree`）。
struct TaskBubblePage: View {
    let data: BubbleData
    let focus: Card
    let editing: CardEditing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let overview = focus.id == data.goal.id
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if overview { lane } else { back }
                Spacer(minLength: 8)
                more
            }
            .frame(height: TaskMetrics.rowHeight)
            HStack(alignment: .top, spacing: BubbleMetrics.titleGap) {
                GoalCheck(task: focus, subtasks: overview ? data.progress : nil).padding(.top, BubbleMetrics.ringTop)
                TaskEditor(card: focus, editing: editing).padding(.trailing, BubbleMetrics.textTrailing)
            }
            if overview, !data.steps.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(data.steps) { TaskLine(task: $0, step: true) }
                }
                .padding(.leading, BubbleMetrics.stepLead).padding(.trailing, BubbleMetrics.textTrailing)
                .padding(.top, Spacing.tight)
                .animation(Motion.fade, value: data.steps.map(\.id))
            }
        }
    }

    private var lane: some View {
        HStack(spacing: BubbleMetrics.titleGap) {
            BoardLaneMark(column: data.column, size: BubbleMetrics.laneMark).frame(width: TaskMetrics.chipTarget)
            Text(data.column.title).font(BubbleMetrics.laneFont).foregroundStyle(palette.ink2).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(data.progress.map(TaskCopy.progress) ?? "")
    }

    private var back: some View {
        Button { workspace.openTask(data.goal) } label: {
            HStack(spacing: BubbleMetrics.titleGap) {
                Image(.back).font(BubbleMetrics.laneFont).frame(width: TaskMetrics.chipTarget)
                Text(data.goal.title).font(BubbleMetrics.laneFont.weight(.regular)).lineLimit(1)
            }
            .foregroundStyle(palette.ink2)
            .frame(height: TaskMetrics.rowHeight).contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("返回 \(data.goal.title)")
    }

    private var more: some View {
        Menu { CardActions(card: focus, more: true) } label: {
            Image(.more).font(BubbleMetrics.laneFont).foregroundStyle(palette.ink2)
                .frame(width: TaskMetrics.chipTarget, height: TaskMetrics.chipTarget).contentShape(.rect)
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(PressStyle(.button)).menuIndicator(.hidden).fixedSize()
        #endif
        .accessibilityLabel("更多")
    }
}

private struct TaskEditor: View {
    let card: Card
    let editing: CardEditing
    @Environment(\.palette) private var palette

    var body: some View {
        let theme = CueEditorTheme.task(palette, done: card.status == .done)
        field(theme).overlay(alignment: .bottomLeading) { BodyHint(editing: editing, inset: theme.verticalInset) }
    }

    @ViewBuilder private func field(_ theme: CueEditorTheme) -> some View {
        #if os(macOS)
        editing.fittedField(card, theme: theme)
        #else
        CardTextField(card: card, editing: editing, theme: theme, fits: true)
        #endif
    }
}

/// 正文还没写时第二段（空段）上的提示。点它就是点进那一段：不拦点按。只占那空段的一行，大字号下截断：折成两行就往上叠到标题上。只看标题那一行之后有没有字，每敲一个字的开销不随正文变长。
private struct BodyHint: View {
    let editing: CardEditing
    let inset: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        let text = editing.text
        if let newline = text.firstIndex(of: "\n"), text.index(after: newline) == text.endIndex {
            Text("写正文：要 Agent 做什么")
                .font(Typography.taskBody)
                .foregroundStyle(palette.ink3)
                .lineLimit(1)
                .padding(.bottom, inset)
                .allowsHitTesting(false)
                .readerHidden(true)
        }
    }
}

extension CueEditorTheme {
    static func task(_ palette: Palette, done: Bool) -> CueEditorTheme {
        var theme = editor(palette, horizontalInset: 0)
        theme.font = Typography.taskBodyFont
        theme.textColor = CueColor(palette.ink2)
        theme.lineSpacing = Typography.taskLineSpacing
        theme.verticalInset = BubbleMetrics.editorInset
        theme.title = Title(font: Typography.taskTitleFont, color: CueColor(done ? palette.ink3 : palette.ink), spacing: Spacing.item)
        return theme
    }
}
