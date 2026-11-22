import CueEditor
import CueStore
import CueText
import SwiftUI

struct TaskBubblePage: View {
    let data: BubbleData
    let focus: Card
    let editing: CardEditing
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents
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
                let lead: Card? = if case .start(let leaf)? = workspace.lead(of: data.steps, in: agents) { leaf } else { nil }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(data.steps) { TaskLine(task: $0, step: true, inBubble: true, leads: $0.id == lead?.id) }
                }
                .padding(.leading, BubbleMetrics.stepLead).padding(.trailing, BubbleMetrics.textTrailing)
                .padding(.top, Spacing.tight)
                .animation(Motion.fade, value: data.steps.map(\.id))
                #if os(macOS)
                .modifier(LaunchAgain(leaf: lead))
                #endif
            }
        }
    }

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

#if os(macOS)
private struct LaunchAgain: ViewModifier {
    let leaf: Card?
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        content.background { if let leaf { Color.clear.confirmsLaunchAgain(workspace.sessionLaunching(.card(leaf.id))) } }
    }
}
#endif

private struct TaskEditor: View {
    let card: Card
    let editing: CardEditing
    @Environment(\.palette) private var palette

    var body: some View {
        let theme = CueEditorTheme.task(palette, done: card.status == .done)
        let names = CueVariables.names(in: editing.text)
        VStack(alignment: .leading, spacing: Spacing.tight) {
            field(theme).overlay(alignment: .bottomLeading) { BodyHint(editing: editing, inset: theme.verticalInset) }
            if !names.isEmpty { VariablesFields(card: card, names: names) }
        }
    }

    @ViewBuilder private func field(_ theme: CueEditorTheme) -> some View {
        #if os(macOS)
        editing.fittedField(card, theme: theme)
        #else
        CardTextField(card: card, editing: editing, theme: theme, fits: true)
        #endif
    }
}

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
