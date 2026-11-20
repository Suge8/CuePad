import CueEditor
import CueStore
import SwiftUI

/// 标题是正文的首段，同一个编辑器（`CardEditing` 的 `titled`），从第一帧就在、就可编辑：点下去字不挪、行高不变、纸不变高（没有"先显示字、点了换输入框"的那一下）。
/// 同新会话、记任务的输入框一种排法：顶上一颗胶囊（总览是挂在哪个项目、点开换；子任务是回上级），中间是字，底下一排、主钮在右下（`BubbleFooter`）。
/// 没有"⋯"：完成是标题旁的圈，其余操作在卡的右键菜单里（`CardMenu.sections`）。
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
                if !overview { back } else if data.goal.parentID == nil { project }
                Spacer(minLength: 0)
            }
            .padding(.leading, BubbleMetrics.ringInset)
            HStack(alignment: .top, spacing: BubbleMetrics.titleGap) {
                GoalCheck(task: focus, subtasks: overview ? data.progress : nil).padding(.top, BubbleMetrics.ringTop)
                TaskEditor(card: focus, editing: editing).padding(.trailing, BubbleMetrics.textTrailing)
            }
            .padding(.top, Spacing.item)
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

    /// 同输入框的去处胶囊（`DestinationChip`）：子任务跟着上级走，不单独换。
    private var project: some View {
        let goal = data.goal, current = workspace.catalog?.project(goal.projectID)
        return MenuButton(sections: [
            ChoiceMenu.Section(choices: (workspace.catalog?.projects ?? []).map { item in
                ChoiceMenu.Choice(title: .verbatim(item.shownName), checked: item.id == goal.projectID) {
                    if item.id != goal.projectID { workspace.move(goal.id, to: .top(project: item.id), after: nil) }
                }
            }),
        ], accessibilityLabel: "移到项目", value: current?.shownName) {
            DestinationChip(project: current)
        }
    }

    private var back: some View {
        Button { workspace.openTask(data.goal) } label: {
            HStack(spacing: Spacing.tight) {
                Image(.back).foregroundStyle(palette.ink3)
                Text(data.goal.title)
            }
            .chip()
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("返回 \(data.goal.title)")
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
            Text("补充细节")
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
